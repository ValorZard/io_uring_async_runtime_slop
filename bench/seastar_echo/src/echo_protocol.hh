//  Shared pieces for the seastar side of the comparison: the same 32-byte
//  wire format the Ada demo and bench/tokio_echo speak, and the same CPU
//  pinning the Ada runtime does with `CPU =>` aspects.
//
//  Nothing here touches seastar, deliberately: the wire format is what the
//  three implementations have to agree on byte for byte, so it is kept
//  compilable on its own and checked by test/protocol_check.cc.

#pragma once

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sched.h>

namespace echo {

inline constexpr std::size_t frame_size  = 32;
inline constexpr std::size_t digits_first = 6;
inline constexpr std::size_t digits_last  = 14;
inline constexpr std::uint32_t max_sequence = 999'999'999;

using frame = std::array<char, frame_size>;

enum class kind { ping, pong, farewell, malformed };

inline const char* tag_of(kind k) {
    switch (k) {
        case kind::ping:      return "PING";
        case kind::pong:      return "PONG";
        case kind::farewell:  return "BYE ";
        case kind::malformed: return "????";
    }
    return "????";
}

//  Byte for byte what Echo_Protocol.Build produces: the four-character tag,
//  then the sequence right-aligned in the digit field, spaces elsewhere.
inline void build(kind k, std::uint32_t sequence, frame& into) {
    into.fill(' ');
    std::memcpy(into.data(), tag_of(k), 4);

    std::uint32_t rest = sequence > max_sequence ? max_sequence : sequence;
    for (std::size_t i = digits_last + 1; i-- > digits_first; ) {
        into[i] = static_cast<char>('0' + rest % 10);
        rest /= 10;
    }
}

struct parsed {
    kind k = kind::malformed;
    std::uint32_t sequence = 0;
};

inline parsed parse(const char* from) {
    parsed out;
    if (std::memcmp(from, "PING", 4) == 0) {
        out.k = kind::ping;
    } else if (std::memcmp(from, "PONG", 4) == 0) {
        out.k = kind::pong;
    } else if (std::memcmp(from, "BYE ", 4) == 0) {
        out.k = kind::farewell;
    } else {
        return {};
    }

    std::uint32_t value = 0;
    for (std::size_t i = digits_first; i <= digits_last; ++i) {
        const char d = from[i];
        if (d < '0' || d > '9') {
            return {};
        }
        value = value * 10 + static_cast<std::uint32_t>(d - '0');
    }
    out.sequence = value;
    return out;
}

//  ---------------------------------------------------------------------
//  The knobs bench.sh sets, read the same way the tokio binaries read them
//  ---------------------------------------------------------------------

//  Parse a "1,2,3,4" CPU list out of an environment variable.
inline std::vector<unsigned> cpu_list(const char* var) {
    std::vector<unsigned> cpus;
    const char* raw = std::getenv(var);
    if (raw == nullptr) {
        return cpus;
    }
    const std::string text{raw};
    std::size_t at = 0;
    while (at < text.size()) {
        std::size_t comma = text.find(',', at);
        if (comma == std::string::npos) {
            comma = text.size();
        }
        const std::string piece = text.substr(at, comma - at);
        try {
            if (!piece.empty()) {
                cpus.push_back(static_cast<unsigned>(std::stoul(piece)));
            }
        } catch (...) {
            //  A malformed entry is ignored rather than fatal: the pinning
            //  is a fairness measure, not a correctness one.
        }
        at = comma + 1;
    }
    return cpus;
}

//  Pin the calling thread to one CPU, the way the Ada tasks' `CPU =>`
//  aspect does.  Seastar pins its own reactor threads from --cpuset; this
//  is for the thread that runs before the reactor starts.
inline void pin_to(unsigned cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    sched_setaffinity(0, sizeof(set), &set);
}

inline std::uint32_t arg_or(int argc, char** argv, int index, std::uint32_t fallback) {
    if (index >= argc) {
        return fallback;
    }
    try {
        return static_cast<std::uint32_t>(std::stoul(argv[index]));
    } catch (...) {
        return fallback;
    }
}

}  // namespace echo
