#[tokio::main]
async fn main() {
    if let Err(error) = hedone_core::web_service::run().await {
        eprintln!("Hedone: {error}");
        std::process::exit(1);
    }
}
