//  seastar_echo_server -- the same server as examples/echo_server.adb, on
//  seastar.
//
//      ./seastar_echo_server [port] [connections-to-serve]
//
//  Structure is deliberately the same shape as the Ada one: one listener
//  per shard sharing a port, and each connection read as a 32-byte frame
//  answered with PONG until the client says BYE.  A connections-to-serve of
//  zero means run until killed.
//
//  Two things are worth knowing before reading a number this produces.
//
//  Seastar takes its own configuration from argv, not from the positional
//  arguments bench.sh passes, so the two are separated below: the
//  positional ones are read here and the rest of argv is built for seastar
//  out of IOUR_BENCH_CPUS, the same variable the tokio binaries read, so
//  all three servers end up pinned to the same cores.
//
//  And seastar's reactor polls before it sleeps -- 200 microseconds by
//  default -- so on a request/response workload it will report more CPU per
//  round trip than a runtime that blocks in the kernel.  That is a real
//  difference in design, not a measurement error, but if you want the two
//  compared with polling out of the picture, pass
//  SEASTAR_EXTRA_ARGS="--idle-poll-time-us=0".

#include "echo_protocol.hh"

#include <seastar/core/app-template.hh>
#include <seastar/core/do_with.hh>
#include <seastar/core/future.hh>
#include <seastar/core/loop.hh>
#include <seastar/core/reactor.hh>
#include <seastar/core/seastar.hh>
#include <seastar/core/sharded.hh>
#include <seastar/core/smp.hh>
#include <seastar/core/temporary_buffer.hh>
#include <seastar/net/api.hh>

#include <atomic>
#include <cstdio>
#include <exception>

#include "seastar_args.hh"

namespace {

//  How many connections to serve before winding down, and how many have
//  been served.  These two are ordinary atomics rather than sharded state,
//  which is worth justifying in a codebase whose whole point is not
//  sharing: they are touched once per connection, at its very end, and
//  never per frame.  The alternative -- a map_reduce over the shards after
//  every connection -- would put cross-core traffic on the path being
//  measured in order to keep the stopping rule pure.
std::atomic<std::uint64_t> g_goal{0};
std::atomic<std::uint64_t> g_completed{0};
std::atomic<std::uint64_t> g_accepted{0};
std::atomic<bool> g_winding_down{false};

struct shard_stats {
    std::uint64_t accepted = 0;
    std::uint64_t completed = 0;
    std::uint64_t rejected = 0;
    std::uint64_t frames = 0;
    std::uint64_t errors = 0;
    std::uint64_t live = 0;
    std::uint64_t peak_live = 0;

    void add(const shard_stats& other) {
        accepted += other.accepted;
        completed += other.completed;
        rejected += other.rejected;
        frames += other.frames;
        errors += other.errors;
        peak_live += other.peak_live;
    }
};

class echo_shard;
seastar::sharded<echo_shard>* g_server = nullptr;

//  One connection's worth of state, kept alive by do_with for as long as
//  the handler runs -- seastar's equivalent of the Ada handler's frame,
//  which lives on the fiber's own stack.
struct connection_state {
    echo::frame response{};
    std::uint64_t frames = 0;
    bool failed = false;
};

class echo_shard {
    seastar::server_socket _listener;
    bool _listening = false;
    shard_stats _stats;

public:
    //  One listening socket per shard on the same port.  Every shard binding
    //  the same port is what gives each core its own accept queue, exactly
    //  as the Ada server's one-listener-per-shard SO_REUSEPORT arrangement
    //  does.
    seastar::future<> listen_on(std::uint16_t port) {
        seastar::listen_options lo;
        lo.reuse_address = true;
        lo.lba = seastar::server_socket::load_balancing_algorithm::port;
        _listener = seastar::listen(seastar::make_ipv4_address({port}), lo);
        _listening = true;
        return seastar::make_ready_future<>();
    }

    //  Accept until the listener is aborted, which is what stop() does.
    seastar::future<> serve() {
        return seastar::keep_doing([this] {
                   return _listener.accept().then(
                       [this](seastar::accept_result res) {
                           note_accepted();
                           //  Detached on purpose: the accept loop must not
                           //  wait for one conversation to finish before it
                           //  takes the next.  The gate below is what makes
                           //  shutdown wait for them instead.
                           (void)handle(std::move(res.connection))
                               .handle_exception([](std::exception_ptr) {});
                       });
               })
            .handle_exception([](std::exception_ptr) {
                //  abort_accept() completes the pending accept with an
                //  exception; that is the loop's exit, not a failure.
                return seastar::make_ready_future<>();
            });
    }

    seastar::future<> stop() {
        if (_listening) {
            _listening = false;
            _listener.abort_accept();
        }
        return seastar::make_ready_future<>();
    }

    shard_stats snapshot() const { return _stats; }

private:
    void note_accepted() {
        ++_stats.accepted;
        ++_stats.live;
        if (_stats.live > _stats.peak_live) {
            _stats.peak_live = _stats.live;
        }
        g_accepted.fetch_add(1, std::memory_order_relaxed);
    }

    //  Reads as a blocking conversation and is not one, the same way the
    //  Ada handler does -- each read and write below suspends this
    //  continuation and lets the core serve other connections.
    seastar::future<> handle(seastar::connected_socket socket) {
        socket.set_nodelay(true);
        auto in = socket.input();
        auto out = socket.output();
        return seastar::do_with(
            std::move(socket), std::move(in), std::move(out), connection_state{},
            [this](seastar::connected_socket&, seastar::input_stream<char>& in,
                   seastar::output_stream<char>& out, connection_state& st) {
                return seastar::repeat([this, &in, &out, &st] {
                           return in.read_exactly(echo::frame_size)
                               .then([&out, &st](seastar::temporary_buffer<char> buf) {
                                   if (buf.size() < echo::frame_size) {
                                       //  Peer closed, or closed mid-frame.
                                       return seastar::make_ready_future<
                                           seastar::stop_iteration>(
                                           seastar::stop_iteration::yes);
                                   }

                                   const echo::parsed p = echo::parse(buf.get());
                                   if (p.k == echo::kind::farewell) {
                                       return seastar::make_ready_future<
                                           seastar::stop_iteration>(
                                           seastar::stop_iteration::yes);
                                   }
                                   if (p.k != echo::kind::ping) {
                                       st.failed = true;
                                       return seastar::make_ready_future<
                                           seastar::stop_iteration>(
                                           seastar::stop_iteration::yes);
                                   }

                                   echo::build(echo::kind::pong, p.sequence,
                                               st.response);
                                   return out
                                       .write(st.response.data(),
                                              st.response.size())
                                       .then([&out] { return out.flush(); })
                                       .then([&st] {
                                           ++st.frames;
                                           return seastar::stop_iteration::no;
                                       });
                               });
                       })
                    .then_wrapped([&out](seastar::future<> f) {
                        //  A peer that vanished mid-conversation is ordinary,
                        //  not an error worth counting -- the same call the
                        //  Ada version makes.
                        f.ignore_ready_future();
                        return out.close().handle_exception(
                            [](std::exception_ptr) {});
                    })
                    .then([this, &st] { note_completed(st); });
            });
    }

    void note_completed(const connection_state& st) {
        ++_stats.completed;
        _stats.frames += st.frames;
        if (st.failed) {
            ++_stats.errors;
        }
        if (_stats.live > 0) {
            --_stats.live;
        }

        const std::uint64_t goal = g_goal.load(std::memory_order_relaxed);
        const std::uint64_t done =
            g_completed.fetch_add(1, std::memory_order_relaxed) + 1;

        //  The connection we were counting to.  Exactly one shard gets
        //  here, and it asks every shard to stop accepting; the accept
        //  loops then return and the app winds down.
        if (goal > 0 && done >= goal &&
            !g_winding_down.exchange(true, std::memory_order_relaxed)) {
            (void)seastar::smp::invoke_on_all([] {
                return g_server->local().stop();
            }).handle_exception([](std::exception_ptr) {});
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    //  Positional arguments first: seastar would reject them, and bench.sh
    //  passes them the same way it does to the Ada and tokio servers.
    const std::uint16_t port =
        static_cast<std::uint16_t>(echo::arg_or(argc, argv, 1, 9099));
    const std::uint64_t goal = echo::arg_or(argc, argv, 2, 0);
    g_goal.store(goal, std::memory_order_relaxed);

    seastar_args args{argv[0]};

    seastar::app_template app;
    seastar::sharded<echo_shard> server;
    g_server = &server;

    return app.run(args.argc(), args.argv(), [&] {
        return server.start()
            .then([&] {
                return server.invoke_on_all(&echo_shard::listen_on, port);
            })
            .then([&] {
                //  bench.sh waits for this line before starting its client,
                //  so it has to name the port and it has to come after the
                //  listeners are actually up.
                std::printf(
                    "seastar_echo_server: listening on port %u with %u shards\n",
                    static_cast<unsigned>(port),
                    static_cast<unsigned>(seastar::smp::count));
                if (goal > 0) {
                    std::printf(
                        "seastar_echo_server: will serve %llu connections, "
                        "then stop\n",
                        static_cast<unsigned long long>(goal));
                } else {
                    std::printf("seastar_echo_server: serving until killed\n");
                }
                std::fflush(stdout);

                return server.invoke_on_all(&echo_shard::serve);
            })
            .then([&] {
                return server.map_reduce0(
                    [](echo_shard& s) { return s.snapshot(); }, shard_stats{},
                    [](shard_stats acc, shard_stats one) {
                        acc.add(one);
                        return acc;
                    });
            })
            .then([&](shard_stats total) {
                std::printf("\n");
                std::printf(
                    "seastar_echo_server: accepted %llu, completed %llu, "
                    "rejected %llu\n",
                    static_cast<unsigned long long>(total.accepted),
                    static_cast<unsigned long long>(total.completed),
                    static_cast<unsigned long long>(total.rejected));
                std::printf(
                    "seastar_echo_server: frames echoed %llu, protocol errors "
                    "%llu\n",
                    static_cast<unsigned long long>(total.frames),
                    static_cast<unsigned long long>(total.errors));
                std::printf(
                    "seastar_echo_server: peak concurrent connections %llu\n",
                    static_cast<unsigned long long>(total.peak_live));
                std::fflush(stdout);
                return server.stop().then(
                    [errors = total.errors] { return errors == 0 ? 0 : 1; });
            })
            .then([](int status) {
                seastar::engine().exit(status);
                return seastar::make_ready_future<>();
            });
    });
}
