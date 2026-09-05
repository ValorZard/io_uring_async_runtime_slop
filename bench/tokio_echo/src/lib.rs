//! Shared pieces for the tokio side of the comparison: the same 32-byte wire
//! format the Ada demo speaks, and -- in `platform` -- the same CPU pinning,
//! descriptor limit and listen backlog the Ada runtime arranges for itself.
//! Everything platform-shaped is in that one module, which has a Linux half
//! and a Windows half, so the rest of this crate is the protocol and nothing
//! else.

pub const FRAME_SIZE: usize = 32;
pub const DIGITS_FIRST: usize = 6;
pub const DIGITS_LAST: usize = 14;
pub const MAX_SEQUENCE: u32 = 999_999_999;

pub type Frame = [u8; FRAME_SIZE];

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Kind {
    Ping,
    Pong,
    Farewell,
    Malformed,
}

fn tag(kind: Kind) -> &'static [u8; 4] {
    match kind {
        Kind::Ping => b"PING",
        Kind::Pong => b"PONG",
        Kind::Farewell => b"BYE ",
        Kind::Malformed => b"????",
    }
}

/// Byte-for-byte the frame `Echo_Protocol.Build` produces.
pub fn build(kind: Kind, sequence: u32, into: &mut Frame) {
    into.fill(b' ');
    into[0..4].copy_from_slice(tag(kind));

    let mut rest = if sequence > MAX_SEQUENCE { MAX_SEQUENCE } else { sequence };
    for i in (DIGITS_FIRST..=DIGITS_LAST).rev() {
        into[i] = b'0' + (rest % 10) as u8;
        rest /= 10;
    }
}

pub fn parse(from: &Frame) -> (Kind, u32) {
    let kind = match &from[0..4] {
        b"PING" => Kind::Ping,
        b"PONG" => Kind::Pong,
        b"BYE " => Kind::Farewell,
        _ => return (Kind::Malformed, 0),
    };

    let mut value: u32 = 0;
    for i in DIGITS_FIRST..=DIGITS_LAST {
        let d = from[i];
        if !d.is_ascii_digit() {
            return (Kind::Malformed, 0);
        }
        value = value * 10 + (d - b'0') as u32;
    }
    (kind, value)
}

//  There was a `platform` module here: CPU pinning, an rlimit raise, and a
//  hand-rolled socket/bind/listen that asked for a 4096 backlog.  All three
//  existed to hold this binary to the same conditions as the Ada one, and
//  none of them is anything a tokio program would ordinarily contain -- they
//  were `unsafe`, they were `libc` on one system and `kernel32` on the other,
//  and between them they were the only reason this crate was not portable
//  safe Rust.
//
//  They are gone, and what is measured now is what someone would actually
//  deploy: `#[tokio::main]`, `TcpListener::bind`, and whatever the runtime
//  decides to do with the machine.  See scripts/bench.sh for what that does
//  and does not make comparable.

pub fn arg_or(args: &[String], index: usize, default: u32) -> u32 {
    args.get(index)
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(default)
}
