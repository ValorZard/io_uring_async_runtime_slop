//  seastar_args -- the command line seastar wants, built from the
//  environment the benchmark sets.
//
//  bench.sh calls every server the same way -- "<binary> <port> <conns>" --
//  and says which cores to run on in IOUR_BENCH_CPUS, because the Ada
//  runtime's own pinning is a compile-time CPU aspect and the tokio
//  binaries read that variable to match it.  Seastar instead takes its core
//  set from its own argv (--smp, --cpuset), and would reject the positional
//  arguments outright.
//
//  So the two command lines are kept apart: the caller reads the positional
//  arguments with echo::arg_or, and this builds the argv seastar sees.
//  Anything else you want to pass through -- a reactor backend, a memory
//  limit, --idle-poll-time-us -- goes in SEASTAR_EXTRA_ARGS.

#pragma once

#include "echo_protocol.hh"

#include <cstdlib>
#include <string>
#include <vector>

class seastar_args {
public:
    explicit seastar_args(const char* program) {
        _args.emplace_back(program);

        const std::vector<unsigned> cpus = echo::cpu_list("IOUR_BENCH_CPUS");
        if (!cpus.empty()) {
            std::string set;
            for (std::size_t i = 0; i < cpus.size(); ++i) {
                if (i != 0) {
                    set += ',';
                }
                set += std::to_string(cpus[i]);
            }
            //  Both, and deliberately: --cpuset says which cores, --smp says
            //  how many reactors, and seastar will not infer one from the
            //  other in every version.
            _args.push_back("--cpuset=" + set);
            _args.push_back("--smp=" + std::to_string(cpus.size()));
            _shards = static_cast<unsigned>(cpus.size());
        }

        //  Seastar reserves a slice of memory per shard up front and will
        //  refuse to start if it cannot; a container with a modest limit
        //  needs to be told what it may take.  This is also where a
        //  reactor backend goes, which is the knob that matters most when
        //  comparing against an io_uring runtime:
        //
        //      SEASTAR_EXTRA_ARGS="--reactor-backend=io_uring --memory=2G"
        if (const char* extra = std::getenv("SEASTAR_EXTRA_ARGS")) {
            const std::string text{extra};
            std::size_t at = 0;
            while (at < text.size()) {
                const std::size_t space = text.find(' ', at);
                const std::size_t end = space == std::string::npos ? text.size() : space;
                if (end > at) {
                    _args.push_back(text.substr(at, end - at));
                }
                at = end + 1;
            }
        }

        _argv.reserve(_args.size() + 1);
        for (std::string& a : _args) {
            _argv.push_back(a.data());
        }
        _argv.push_back(nullptr);
    }

    int argc() const { return static_cast<int>(_args.size()); }
    char** argv() { return _argv.data(); }

    //  Reactors seastar will start, for reporting.  Zero means "seastar's
    //  own default", which is one per available core.
    unsigned shards() const { return _shards; }

private:
    //  _argv points into these, so they must not move after construction.
    std::vector<std::string> _args;
    std::vector<char*> _argv;
    unsigned _shards = 0;
};
