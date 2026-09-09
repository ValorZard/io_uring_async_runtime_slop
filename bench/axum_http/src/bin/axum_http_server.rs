use axum::{http::header, response::IntoResponse, routing::get, Router};
use std::{env, net::SocketAddr, process, sync::{atomic::{AtomicUsize, Ordering}, Arc}};
use tokio::{net::TcpListener, sync::Notify};

const BODY: &str = "0123456789abcdef0123456789abcdef";

#[derive(Clone)]
struct State {
    completed: Arc<AtomicUsize>,
    goal: usize,
    stopped: Arc<Notify>,
}

fn argument(index: usize, fallback: u16) -> u16 {
    env::args().nth(index).map_or(Ok(fallback), |value| value.parse())
        .unwrap_or_else(|_| { eprintln!("invalid argument"); process::exit(2) })
}

async fn reply(axum::extract::State(state): axum::extract::State<State>) -> impl IntoResponse {
    let completed = state.completed.fetch_add(1, Ordering::Relaxed) + 1;
    if state.goal != 0 && completed == state.goal {
        state.stopped.notify_one();
    }
        ([(header::CONTENT_TYPE, "application/octet-stream"),
            (header::CONNECTION, "close"),
            (header::CONTENT_LENGTH, "32")], BODY)
        .into_response()
}

#[tokio::main]
async fn main() {
    let port = argument(1, 8080);
    let goal = argument(2, 0) as usize;
    let state = State { completed: Arc::new(AtomicUsize::new(0)), goal, stopped: Arc::new(Notify::new()) };
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port))).await
        .unwrap_or_else(|error| { eprintln!("{error}"); process::exit(1) });
    println!("axum_http_server: listening on port {port}");
    let stopped = state.stopped.clone();
    let app = Router::new().route("/", get(reply)).with_state(state.clone());
    axum::serve(listener, app).with_graceful_shutdown(async move {
        if goal != 0 { stopped.notified().await; } else { std::future::pending::<()>().await; }
    }).await.unwrap();
    println!("axum_http_server: requests completed {}", state.completed.load(Ordering::Relaxed));
}