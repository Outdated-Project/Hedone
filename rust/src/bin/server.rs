#[tokio::main]
async fn main() {
    if let Err(error) = hghub_core::web_service::run().await {
        eprintln!("HGhub: {error}");
        std::process::exit(1);
    }
}
