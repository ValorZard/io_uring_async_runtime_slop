//  seastar_echo_client -- the same load generator as
//  examples/echo_client.adb and bench/tokio_echo's client.
//
//      ./seastar_echo_client [host] [port] [connections] [rounds]
//
//  One session per connection, all in flight at once; each does `rounds`
//  PING/PONG round trips, says BYE, and closes.  The reported figure is the
//  Ada client's: total frames divided by wall time, where wall time covers
//  connect, the rounds, and teardown.
//
//  The connections are dealt out across the shards rather than opened from
//  one, so the load generator is not itself the bottleneck -- the same
//  reason the Ada client runs its connections on every shard.

#include "echo_protocol.hh"
#include "seastar_args.hh"

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
#include <seastar/net/inet_address.hh>

#include <boost/range/irange.hpp>

#include <chrono>
#include <cstdio>
#include <exception>
#include <string>

namespace {

struct session_stats {
    std::uint64_t started = 0;
    std::uint64_t ok = 0;
    std::uint64_t failed = 0;
    std::uint64_t frames = 0;
    std::uint64_t mismatched = 0;
    std::uint64_t live = 0;
    std::uint64_t peak_live = 0;

    void add(const session_stats& other) {
        started += other.started;
        ok += other.ok;
        failed += other.failed;
        frames += other.frames;
        mismatched += other.mismatched;
        peak_live += other.peak_live;
    }
};

//  One session's state, kept alive by do_with for as long as it runs.
struct session_state {
    echo::frame outgoing{};
    std::uint64_t frames = 0;
    std::uint32_t round = 0;
    bool ok = true;
    bool mismatch = false;
};

class client_shard {
    session_stats _stats;
    std::string _host;
    std::uint16_t _port = 0;
    std::uint32_t _rounds = 0;

public:
    seastar::future<> configure(std::string host, std::uint16_t port,
                                std::uint32_t rounds) {
        _host = std::move(host);
        _port = port;
        _rounds = rounds;
        return seastar::make_ready_future<>();
    }

    //  Every session this shard is responsible for, all in flight together.
    seastar::future<> run(unsigned sessions) {
        return seastar::parallel_for_each(
            boost::irange(0u, sessions),
            [this](unsigned) { return session(); });
    }

    session_stats snapshot() const { return _stats; }

    seastar::future<> stop() { return seastar::make_ready_future<>(); }

private:
    void started_one() {
        ++_stats.started;
        ++_stats.live;
        if (_stats.live > _stats.peak_live) {
            _stats.peak_live = _stats.live;
        }
    }

    void finished_one(const session_state& st) {
        _stats.frames += st.frames;
        if (st.ok) {
            ++_stats.ok;
        } else {
            ++_stats.failed;
        }
        if (st.mismatch) {
            ++_stats.mismatched;
        }
        if (_stats.live > 0) {
            --_stats.live;
        }
    }

    seastar::future<> session() {
        started_one();

        seastar::socket_address addr{
            seastar::ipv4_addr{_host, _port}};

        return seastar::connect(addr)
            .then([this](seastar::connected_socket socket) {
                //  The Ada client's sockets come from Tcp_Socket, which sets
                //  TCP_NODELAY.
                socket.set_nodelay(true);
                auto in = socket.input();
                auto out = socket.output();
                return seastar::do_with(
                    std::move(socket), std::move(in), std::move(out),
                    session_state{},
                    [this](seastar::connected_socket&,
                           seastar::input_stream<char>& in,
                           seastar::output_stream<char>& out,
                           session_state& st) {
                        return converse(in, out, st).then([this, &out, &st] {
                            return farewell(out).then([this, &st] {
                                finished_one(st);
                            });
                        });
                    });
            })
            .handle_exception([this](std::exception_ptr) {
                //  A connection that never came up counts as a failed
                //  session, exactly as it does in the other two clients.
                session_state failed;
                failed.ok = false;
                finished_one(failed);
            });
    }

    seastar::future<> converse(seastar::input_stream<char>& in,
                               seastar::output_stream<char>& out,
                               session_state& st) {
        return seastar::repeat([this, &in, &out, &st] {
                   if (st.round >= _rounds) {
                       return seastar::make_ready_future<seastar::stop_iteration>(
                           seastar::stop_iteration::yes);
                   }
                   ++st.round;
                   echo::build(echo::kind::ping, st.round, st.outgoing);

                   return out.write(st.outgoing.data(), st.outgoing.size())
                       .then([&out] { return out.flush(); })
                       .then([&in] { return in.read_exactly(echo::frame_size); })
                       .then([&st](seastar::temporary_buffer<char> buf) {
                           if (buf.size() < echo::frame_size) {
                               st.ok = false;
                               return seastar::stop_iteration::yes;
                           }
                           const echo::parsed p = echo::parse(buf.get());
                           if (p.k != echo::kind::pong || p.sequence != st.round) {
                               st.mismatch = true;
                               st.ok = false;
                               return seastar::stop_iteration::yes;
                           }
                           ++st.frames;
                           return seastar::stop_iteration::no;
                       });
               })
            .handle_exception([&st](std::exception_ptr) {
                st.ok = false;
                return seastar::make_ready_future<>();
            });
    }

    seastar::future<> farewell(seastar::output_stream<char>& out) {
        return seastar::do_with(echo::frame{}, [&out](echo::frame& bye) {
            echo::build(echo::kind::farewell, 0, bye);
            return out.write(bye.data(), bye.size())
                .then([&out] { return out.flush(); })
                .then([&out] { return out.close(); })
                .handle_exception([](std::exception_ptr) {});
        });
    }
};

}  // namespace

int main(int argc, char** argv) {
    const std::string host =
        argc > 1 ? std::string{argv[1]} : std::string{"127.0.0.1"};
    const std::uint16_t port =
        static_cast<std::uint16_t>(echo::arg_or(argc, argv, 2, 9099));
    const unsigned connections = echo::arg_or(argc, argv, 3, 1000);
    const std::uint32_t rounds = echo::arg_or(argc, argv, 4, 8);

    seastar_args args{argv[0]};

    seastar::app_template app;
    seastar::sharded<client_shard> client;

    return app.run(args.argc(), args.argv(), [&] {
        return client.start()
            .then([&] {
                return client.invoke_on_all(&client_shard::configure, host, port,
                                            rounds);
            })
            .then([&] {
                std::printf(
                    "seastar_echo_client: %s port %u, %u connections, %u "
                    "rounds each\n",
                    host.c_str(), static_cast<unsigned>(port), connections,
                    static_cast<unsigned>(rounds));
                std::printf("seastar_echo_client: %u shards\n",
                            static_cast<unsigned>(seastar::smp::count));
                std::fflush(stdout);

                return seastar::make_ready_future<
                    std::chrono::steady_clock::time_point>(
                    std::chrono::steady_clock::now());
            })
            .then([&](std::chrono::steady_clock::time_point start) {
                //  Deal the sessions out over the shards; the remainder goes
                //  to the low-numbered ones, so the total is exact.
                const unsigned shards =
                    static_cast<unsigned>(seastar::smp::count);
                return client
                    .invoke_on_all([connections, shards](client_shard& cs) {
                        const unsigned id =
                            static_cast<unsigned>(seastar::this_shard_id());
                        unsigned mine = connections / shards;
                        if (id < connections % shards) {
                            ++mine;
                        }
                        return cs.run(mine);
                    })
                    .then([start] { return start; });
            })
            .then([&](std::chrono::steady_clock::time_point start) {
                const double elapsed =
                    std::chrono::duration<double>(
                        std::chrono::steady_clock::now() - start)
                        .count();
                return client
                    .map_reduce0([](client_shard& c) { return c.snapshot(); },
                                 session_stats{},
                                 [](session_stats acc, session_stats one) {
                                     acc.add(one);
                                     return acc;
                                 })
                    .then([elapsed, connections](session_stats total) {
                        //  bench.sh reads "elapsed", "frames exchanged" and
                        //  "round trips per second" out of this, so the
                        //  wording matches the other two clients exactly.
                        std::printf("\n");
                        std::printf(
                            "seastar_echo_client: sessions started %llu, "
                            "succeeded %llu, failed %llu\n",
                            static_cast<unsigned long long>(total.started),
                            static_cast<unsigned long long>(total.ok),
                            static_cast<unsigned long long>(total.failed));
                        std::printf(
                            "seastar_echo_client: frames exchanged %llu, "
                            "protocol mismatches %llu\n",
                            static_cast<unsigned long long>(total.frames),
                            static_cast<unsigned long long>(total.mismatched));
                        std::printf(
                            "seastar_echo_client: peak concurrent sessions "
                            "%llu\n",
                            static_cast<unsigned long long>(total.peak_live));
                        std::printf("seastar_echo_client: elapsed %.9f s\n",
                                    elapsed);
                        if (elapsed > 0.0) {
                            std::printf(
                                "seastar_echo_client: round trips per second "
                                "%.8E\n",
                                static_cast<double>(total.frames) / elapsed);
                        }
                        std::fflush(stdout);

                        return total.ok == connections && total.mismatched == 0
                                   ? 0
                                   : 1;
                    });
            })
            .then([&](int status) {
                return client.stop().then([status] {
                    seastar::engine().exit(status);
                    return seastar::make_ready_future<>();
                });
            });
    });
}
