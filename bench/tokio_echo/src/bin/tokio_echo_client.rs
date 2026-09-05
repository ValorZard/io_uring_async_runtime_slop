//! tokio_echo_client -- the same load generator as examples/echo_client.adb.
//!
//!     ./tokio_echo_client [host] [port] [connections] [rounds]
//!
//! One task per connection, all in flight at once; each does `rounds`
//! PING/PONG round trips, says BYE, and closes.  The reported figure is the
//! Ada client's: total frames divided by wall time, where wall time covers
//! connect, the rounds, and teardown.
//!
//! Plain `#[tokio::main]`: the default multi-thread runtime, on as many
//! workers as tokio thinks the machine has, wherever the OS schedules them.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use tokio_echo::{arg_or, build, parse, Frame, Kind, FRAME_SIZE};

struct Stats {
    started: AtomicUsize,
    ok: AtomicUsize,
    failed: AtomicUsize,
    frames: AtomicUsize,
    mismatched: AtomicUsize,
    live: AtomicUsize,
    peak_live: AtomicUsize,
}

impl Stats {
    fn new() -> Self {
        Stats {
            started: AtomicUsize::new(0),
            ok: AtomicUsize::new(0),
            failed: AtomicUsize::new(0),
            frames: AtomicUsize::new(0),
            mismatched: AtomicUsize::new(0),
            live: AtomicUsize::new(0),
            peak_live: AtomicUsize::new(0),
        }
    }

    fn started_one(&self) {
        self.started.fetch_add(1, Ordering::Relaxed);
        let live = self.live.fetch_add(1, Ordering::Relaxed) + 1;
        self.peak_live.fetch_max(live, Ordering::Relaxed);
    }

    fn finished_one(&self, frames: usize, ok: bool, mismatch: bool) {
        self.frames.fetch_add(frames, Ordering::Relaxed);
        if ok {
            self.ok.fetch_add(1, Ordering::Relaxed);
        } else {
            self.failed.fetch_add(1, Ordering::Relaxed);
        }
        if mismatch {
            self.mismatched.fetch_add(1, Ordering::Relaxed);
        }
        self.live.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn session(host: String, port: u16, rounds: u32, stats: Arc<Stats>) {
    let mut outgoing: Frame = [0u8; FRAME_SIZE];
    let mut incoming: Frame = [0u8; FRAME_SIZE];
    let mut frames = 0usize;
    let mut ok;
    let mut mismatch = false;

    stats.started_one();

    let mut sock = match TcpStream::connect((host.as_str(), port)).await {
        Ok(s) => s,
        Err(_) => {
            stats.finished_one(0, false, false);
            return;
        }
    };
    // The Ada client's sockets come from Tcp_Socket, which sets TCP_NODELAY.
    let _ = sock.set_nodelay(true);

    ok = true;
    for round in 1..=rounds {
        build(Kind::Ping, round, &mut outgoing);

        if sock.write_all(&outgoing).await.is_err() {
            ok = false;
            break;
        }
        if sock.read_exact(&mut incoming).await.is_err() {
            ok = false;
            break;
        }

        let (kind, sequence) = parse(&incoming);
        if kind != Kind::Pong || sequence != round {
            mismatch = true;
            ok = false;
            break;
        }

        frames += 1;
    }

    build(Kind::Farewell, 0, &mut outgoing);
    let _ = sock.write_all(&outgoing).await;
    drop(sock);

    stats.finished_one(frames, ok, mismatch);
}


#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let host = args.first().cloned().unwrap_or_else(|| "127.0.0.1".to_string());
    let port = arg_or(&args, 1, 9099) as u16;
    let connections = arg_or(&args, 2, 1000) as usize;
    let rounds = arg_or(&args, 3, 8);

    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);

    {
        println!(
            "tokio_echo_client: {host} port {port}, {connections} connections,              {rounds} rounds each"
        );
        println!("tokio_echo_client: {workers} workers");

        let stats = Arc::new(Stats::new());
        let start = Instant::now();

        let mut handles = Vec::with_capacity(connections);
        for _ in 0..connections {
            handles.push(tokio::spawn(session(
                host.clone(),
                port,
                rounds,
                stats.clone(),
            )));
        }
        for h in handles {
            let _ = h.await;
        }

        let elapsed = start.elapsed().as_secs_f64();
        let frames = stats.frames.load(Ordering::Relaxed);
        let succeeded = stats.ok.load(Ordering::Relaxed);
        let mismatched = stats.mismatched.load(Ordering::Relaxed);

        println!();
        println!(
            "tokio_echo_client: sessions started {}, succeeded {succeeded}, failed {}",
            stats.started.load(Ordering::Relaxed),
            stats.failed.load(Ordering::Relaxed)
        );
        println!("tokio_echo_client: frames exchanged {frames}, protocol mismatches {mismatched}");
        println!(
            "tokio_echo_client: peak concurrent sessions {}",
            stats.peak_live.load(Ordering::Relaxed)
        );
        println!("tokio_echo_client: elapsed {elapsed:.9} s");
        if elapsed > 0.0 {
            println!(
                "tokio_echo_client: round trips per second {:.8E}",
                frames as f64 / elapsed
            );
        }

        std::process::exit(if succeeded == connections && mismatched == 0 {
            0
        } else {
            1
        });
    }
}
