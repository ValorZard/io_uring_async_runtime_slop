//! Shared pieces for the tokio side of the comparison: the same 32-byte wire
//! format the Ada demo speaks, and the same CPU pinning the Ada runtime does
//! with `CPU =>` aspects.

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

/// Pin the calling thread to one CPU, the way the Ada tasks' `CPU =>` aspect
/// does.  Silently does nothing if the id is out of range for the set.
pub fn pin_to(cpu: usize) {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_ZERO(&mut set);
        libc::CPU_SET(cpu, &mut set);
        libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set);
    }
}

/// Parse a "1,2,3,4" CPU list out of an environment variable.
pub fn cpu_list(var: &str) -> Vec<usize> {
    match std::env::var(var) {
        Ok(s) if !s.trim().is_empty() => s
            .split(',')
            .filter_map(|p| p.trim().parse::<usize>().ok())
            .collect(),
        _ => Vec::new(),
    }
}

pub fn arg_or(args: &[String], index: usize, default: u32) -> u32 {
    args.get(index)
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(default)
}
