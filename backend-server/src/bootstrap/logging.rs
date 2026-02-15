use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init(level: &str, json: bool) {
    let filter = EnvFilter::try_new(level).unwrap_or_else(|_| EnvFilter::new("trace"));
    let fmt_layer = fmt::layer();

    if json {
        tracing_subscriber::registry()
            .with(filter)
            .with(fmt_layer.json())
            .init();
        return;
    }

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt_layer)
        .init();
}
