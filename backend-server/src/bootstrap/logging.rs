use std::sync::Arc;

use chrono::Utc;
use tracing::{field::Field, Event, Subscriber};
use tracing_subscriber::{
    fmt,
    layer::{Context, SubscriberExt},
    util::SubscriberInitExt,
    EnvFilter, Layer,
};

use crate::application::runtime_logging::{RuntimeLogSource, RuntimeLogStore};

pub fn init(
    level: &str,
    json: bool,
    console_enabled: bool,
    log_store: Option<Arc<RuntimeLogStore>>,
) {
    let filter = EnvFilter::try_new(level).unwrap_or_else(|_| EnvFilter::new("trace"));
    let runtime_layer = RuntimeLogLayer { log_store };

    if json {
        let fmt_layer = if console_enabled {
            fmt::layer().json().boxed()
        } else {
            fmt::layer().json().with_writer(std::io::sink).boxed()
        };
        tracing_subscriber::registry()
            .with(filter)
            .with(runtime_layer)
            .with(fmt_layer)
            .init();
        return;
    }

    let fmt_layer = if console_enabled {
        fmt::layer().boxed()
    } else {
        fmt::layer().with_writer(std::io::sink).boxed()
    };

    tracing_subscriber::registry()
        .with(filter)
        .with(runtime_layer)
        .with(fmt_layer)
        .init();
}

struct RuntimeLogLayer {
    log_store: Option<Arc<RuntimeLogStore>>,
}

impl<S> Layer<S> for RuntimeLogLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let Some(log_store) = &self.log_store else {
            return;
        };

        let mut visitor = EventVisitor::default();
        event.record(&mut visitor);

        let metadata = event.metadata();
        let mut line = format!(
            "{} {} {}",
            Utc::now().to_rfc3339(),
            metadata.level(),
            metadata.target()
        );

        if let Some(message) = visitor.message.take() {
            line.push(' ');
            line.push_str(&message);
        }

        if !visitor.fields.is_empty() {
            line.push(' ');
            line.push_str(&visitor.fields.join(" "));
        }

        let _ = log_store.append_line(RuntimeLogSource::ServerBackend, line);
    }
}

#[derive(Default)]
struct EventVisitor {
    message: Option<String>,
    fields: Vec<String>,
}

impl tracing::field::Visit for EventVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let rendered = format!("{value:?}");
        if field.name() == "message" {
            self.message = Some(rendered.trim_matches('"').to_string());
            return;
        }
        self.fields.push(format!("{}={rendered}", field.name()));
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_string());
            return;
        }
        self.fields.push(format!("{}={value}", field.name()));
    }
}
