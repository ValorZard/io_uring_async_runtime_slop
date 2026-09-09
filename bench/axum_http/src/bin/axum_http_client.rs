use reqwest::header::CONNECTION;
use std::{env, process, sync::{atomic::{AtomicUsize, Ordering}, Arc}, time::Instant};

const BODY: &str = "0123456789abcdef0123456789abcdef";

fn argument(index: usize, fallback: usize) -> usize {
    env::args().nth(index).map_or(Ok(fallback), |value| value.parse())
        .unwrap_or_else(|_| { eprintln!("invalid argument"); process::exit(2) })
}

#[tokio::main]
async fn main() {
    let host = env::args().nth(1).unwrap_or_else(|| "127.0.0.1".into());
    let port = argument(2, 8080);
    let connections = argument(3, 100);
    let rounds = argument(4, 8);
    let url = format!("http://{host}:{port}/");
    let client = reqwest::Client::builder().pool_max_idle_per_host(0).build().unwrap();
    let succeeded = Arc::new(AtomicUsize::new(0));
    let failed = Arc::new(AtomicUsize::new(0));
    let started = Instant::now();
    let mut tasks = Vec::with_capacity(connections);
    for _ in 0..connections {
        let client = client.clone(); let url = url.clone();
        let succeeded = succeeded.clone(); let failed = failed.clone();
        tasks.push(tokio::spawn(async move {
            for _ in 0..rounds {
                match client.get(&url).header(CONNECTION, "close").send().await {
                    Ok(response) if response.status() == 200 => match response.text().await {
                        Ok(body) if body == BODY => { succeeded.fetch_add(1, Ordering::Relaxed); }
                        _ => { failed.fetch_add(1, Ordering::Relaxed); }
                    },
                    _ => { failed.fetch_add(1, Ordering::Relaxed); }
                }
            }
        }));
    }
    for task in tasks { let _ = task.await; }
    let elapsed = started.elapsed().as_secs_f64();
    let succeeded = succeeded.load(Ordering::Relaxed);
    let failed = failed.load(Ordering::Relaxed);
    println!("axum_http_client: {host} port {port}, {connections} connections, {rounds} rounds each");
    println!("axum_http_client: sessions started {connections}, succeeded {connections}, failed {failed}");
    println!("axum_http_client: frames exchanged {succeeded}");
    println!("axum_http_client: elapsed {elapsed:.9} s");
    if elapsed > 0.0 { println!("axum_http_client: round trips per second {:.8E}", succeeded as f64 / elapsed); }
    if failed != 0 { process::exit(1); }
}