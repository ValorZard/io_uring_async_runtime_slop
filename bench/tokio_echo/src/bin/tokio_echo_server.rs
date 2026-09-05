//! tokio_echo_server -- the same server as examples/echo_server.adb, on tokio.
//!
//!     ./tokio_echo_server [port] [connections-to-serve]
//!
//! Structure is deliberately the same shape as the Ada one: a single acceptor
//! that spawns one task per connection, and each connection reads a 32-byte
//! frame, answers PONG, and stops on BYE.  A connections-to-serve of 0 means
//! run until killed.
//!
//! Worker threads are pinned by IOUR_BENCH_CPUS ("1,2,3,4"), one thread per
//! listed CPU, which is what the Ada shards do with their static CPU aspects.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Notify;

use tokio_echo::{
    arg_or, build, cpu_list, listener_with_backlog, parse, pin_to,
    raise_descriptor_limit, Frame, Kind, FRAME_SIZE,
};

struct Stats {
    accepted: AtomicUsize,
    completed: AtomicUsize,
    frames: AtomicUsize,
    errors: AtomicUsize,
    live: AtomicUsize,
    peak_live: AtomicUsize,
}

impl Stats {
    fn new() -> Self {
        Stats {
            accepted: AtomicUsize::new(0),
            completed: AtomicUsize::new(0),
            frames: AtomicUsize::new(0),
            errors: AtomicUsize::new(0),
            live: AtomicUsize::new(0),
            peak_live: AtomicUsize::new(0),
        }
    }

    fn accepted_one(&self) {
        self.accepted.fetch_add(1, Ordering::Relaxed);
        let live = self.live.fetch_add(1, Ordering::Relaxed) + 1;
        self.peak_live.fetch_max(live, Ordering::Relaxed);
    }

    /// Returns true when this was the connection the server was counting to.
    fn completed_one(&self, frames: usize, failed: bool, goal: usize) -> bool {
        self.frames.fetch_add(frames, Ordering::Relaxed);
        if failed {
            self.errors.fetch_add(1, Ordering::Relaxed);
        }
        self.live.fetch_sub(1, Ordering::Relaxed);
        let done = self.completed.fetch_add(1, Ordering::Relaxed) + 1;
        goal > 0 && done == goal
    }
}

/// One connection, start to finish.
async fn serve(mut conn: TcpStream, stats: Arc<Stats>, goal: usize, shutdown: Arc<Notify>) {
    let mut request: Frame = [0u8; FRAME_SIZE];
    let mut response: Frame = [0u8; FRAME_SIZE];
    let mut frames = 0usize;
    let mut failed = false;

    loop {
        if conn.read_exact(&mut request).await.is_err() {
            break; // peer closed, or the read failed
        }

        let (kind, sequence) = parse(&request);
        if kind == Kind::Farewell {
            break;
        }
        if kind != Kind::Ping {
            failed = true;
            break;
        }

        build(Kind::Pong, sequence, &mut response);
        if conn.write_all(&response).await.is_err() {
            // A peer that vanished mid-conversation is ordinary, not an
            // error worth counting -- same call the Ada version makes.
            break;
        }

        frames += 1;
    }

    drop(conn);

    if stats.completed_one(frames, failed, goal) {
        shutdown.notify_waiters();
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let port = arg_or(&args, 0, 9099) as u16;
    let goal = arg_or(&args, 1, 0) as usize;

    let cpus = cpu_list("IOUR_BENCH_CPUS");
    let main_cpu = cpu_list("IOUR_BENCH_MAIN_CPU");
    if let Some(&c) = main_cpu.first() {
        pin_to(c);
    }

    let workers = if cpus.is_empty() { 4 } else { cpus.len() };
    let next = Arc::new(AtomicUsize::new(0));
    let pin_set = cpus.clone();

    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.worker_threads(workers).enable_all();
    if !pin_set.is_empty() {
        let next = next.clone();
        builder.on_thread_start(move || {
            let i = next.fetch_add(1, Ordering::Relaxed);
            if i < pin_set.len() {
                pin_to(pin_set[i]);
            }
        });
    }
    let rt = builder.build().expect("runtime");

    let fd_limit = raise_descriptor_limit();

    rt.block_on(async move {
        let listener = match listener_with_backlog(port, 4096) {
            Ok(l) => l,
            Err(e) => {
                println!("tokio_echo_server: cannot listen on port {port} ({e})");
                std::process::exit(1);
            }
        };
        let bound = listener.local_addr().map(|a| a.port()).unwrap_or(port);

        println!(
            "tokio_echo_server: listening on port {bound} with {workers} workers, \
             descriptor limit {fd_limit}"
        );
        if goal > 0 {
            println!("tokio_echo_server: will serve {goal} connections, then stop");
        } else {
            println!("tokio_echo_server: serving until killed");
        }

        let stats = Arc::new(Stats::new());
        let shutdown = Arc::new(Notify::new());
        let done = shutdown.notified();
        tokio::pin!(done);

        loop {
            if goal > 0 && stats.accepted.load(Ordering::Relaxed) >= goal {
                break;
            }
            tokio::select! {
                biased;
                _ = &mut done => break,
                res = listener.accept() => match res {
                    Ok((conn, _)) => {
                        stats.accepted_one();
                        tokio::spawn(serve(conn, stats.clone(), goal, shutdown.clone()));
                    }
                    Err(_) => continue,
                },
            }
        }

        // The acceptor stopped because the goal was reached; wait for the
        // last handlers, exactly as the Ada server waits for shutdown.
        if goal > 0 {
            while stats.completed.load(Ordering::Relaxed) < goal {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            }
        }

        let errors = stats.errors.load(Ordering::Relaxed);
        println!();
        println!(
            "tokio_echo_server: accepted {}, completed {}, rejected 0",
            stats.accepted.load(Ordering::Relaxed),
            stats.completed.load(Ordering::Relaxed)
        );
        println!(
            "tokio_echo_server: frames echoed {}, protocol errors {errors}",
            stats.frames.load(Ordering::Relaxed)
        );
        println!(
            "tokio_echo_server: peak concurrent connections {}",
            stats.peak_live.load(Ordering::Relaxed)
        );

        std::process::exit(if errors == 0 { 0 } else { 1 });
    });
}
