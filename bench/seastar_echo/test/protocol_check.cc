//  protocol_check -- the wire format, against the bytes the other two
//  implementations put on the wire.
//
//  Iour.Echo_Protocol (Ada) and bench/tokio_echo (Rust) build the same
//  32-byte frame, and the benchmark crosses every client with every server,
//  so a one-byte disagreement here would show up as a protocol mismatch in
//  a run that otherwise looks healthy.  Rather than trust three
//  reimplementations to agree, this pins the expected bytes literally.
//
//  Needs no seastar: build it with
//      g++ -std=c++20 -O2 -o protocol_check test/protocol_check.cc

#include "../src/echo_protocol.hh"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int failures = 0;

void expect_frame(echo::kind k, std::uint32_t sequence, const std::string& want) {
    echo::frame got{};
    echo::build(k, sequence, got);
    const std::string got_s(got.data(), got.size());
    if (got_s != want) {
        std::printf("  FAIL build(%u): \"%s\"\n            wanted \"%s\"\n",
                    sequence, got_s.c_str(), want.c_str());
        ++failures;
    }
}

void expect_round_trip(echo::kind k, std::uint32_t sequence) {
    echo::frame f{};
    echo::build(k, sequence, f);
    const echo::parsed p = echo::parse(f.data());
    const std::uint32_t want = sequence > echo::max_sequence ? echo::max_sequence : sequence;
    if (p.k != k || p.sequence != want) {
        std::printf("  FAIL round trip: sequence %u came back as %u\n", sequence, p.sequence);
        ++failures;
    }
}

void expect_malformed(const std::string& raw) {
    std::string padded = raw;
    padded.resize(echo::frame_size, ' ');
    if (echo::parse(padded.data()).k != echo::kind::malformed) {
        std::printf("  FAIL: \"%s\" should not have parsed\n", raw.c_str());
        ++failures;
    }
}

}  // namespace

int main() {
    //  Literal bytes: tag in 0..3, sequence right-aligned in 6..14, the
    //  rest spaces.  Positions 4, 5 and 15.. are the padding the Ada
    //  Build leaves behind.
    expect_frame(echo::kind::ping, 1,
                 "PING  000000001                 ");
    expect_frame(echo::kind::pong, 42,
                 "PONG  000000042                 ");
    expect_frame(echo::kind::farewell, 0,
                 "BYE   000000000                 ");
    expect_frame(echo::kind::ping, 999'999'999,
                 "PING  999999999                 ");
    //  Over the maximum is clamped, not wrapped -- the Ada Build does the
    //  same rather than let a longer number run out of its field.
    expect_frame(echo::kind::ping, 1'000'000'000,
                 "PING  999999999                 ");

    for (std::uint32_t s : {0u, 1u, 7u, 99u, 100'000u, 999'999'999u, 1'000'000'001u}) {
        expect_round_trip(echo::kind::ping, s);
        expect_round_trip(echo::kind::pong, s);
    }

    expect_malformed("NOPE  000000001");
    expect_malformed("PING  00000000x");
    expect_malformed("ping  000000001");

    if (failures == 0) {
        std::puts("protocol_check: the wire format matches the Ada and tokio frames");
        return 0;
    }
    std::printf("protocol_check: %d failure(s)\n", failures);
    return 1;
}
