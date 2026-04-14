#[cfg(any(debug_assertions, test))]
use chrono::SecondsFormat;
#[cfg(any(debug_assertions, test))]
use chrono::Utc;
use http::Error as HttpError;
use http::HeaderMap;
use http::HeaderName;
use http::HeaderValue;
use opentelemetry::global;
use opentelemetry::propagation::Injector;
use reqwest::IntoUrl;
use reqwest::Method;
#[cfg(any(debug_assertions, test))]
use reqwest::Request;
use reqwest::Response;
use serde::Serialize;
#[cfg(any(debug_assertions, test))]
use std::collections::BTreeMap;
use std::fmt::Display;
#[cfg(any(debug_assertions, test))]
use std::fs;
#[cfg(any(debug_assertions, test))]
use std::path::Path;
#[cfg(any(debug_assertions, test))]
use std::path::PathBuf;
use std::time::Duration;
use tracing::Span;
use tracing_opentelemetry::OpenTelemetrySpanExt;
#[cfg(any(debug_assertions, test))]
use uuid::Uuid;

#[cfg(debug_assertions)]
const DEBUG_HTTP_REQUEST_LOG_LIMIT: usize = 50;

#[derive(Clone, Debug)]
pub struct CodexHttpClient {
    inner: reqwest::Client,
}

impl CodexHttpClient {
    pub fn new(inner: reqwest::Client) -> Self {
        Self { inner }
    }

    pub fn get<U>(&self, url: U) -> CodexRequestBuilder
    where
        U: IntoUrl,
    {
        self.request(Method::GET, url)
    }

    pub fn post<U>(&self, url: U) -> CodexRequestBuilder
    where
        U: IntoUrl,
    {
        self.request(Method::POST, url)
    }

    pub fn request<U>(&self, method: Method, url: U) -> CodexRequestBuilder
    where
        U: IntoUrl,
    {
        let url_str = url.as_str().to_string();
        CodexRequestBuilder::new(self.inner.request(method.clone(), url), method, url_str)
    }
}

#[must_use = "requests are not sent unless `send` is awaited"]
#[derive(Debug)]
pub struct CodexRequestBuilder {
    builder: reqwest::RequestBuilder,
    method: Method,
    url: String,
}

impl CodexRequestBuilder {
    fn new(builder: reqwest::RequestBuilder, method: Method, url: String) -> Self {
        Self {
            builder,
            method,
            url,
        }
    }

    fn map(self, f: impl FnOnce(reqwest::RequestBuilder) -> reqwest::RequestBuilder) -> Self {
        Self {
            builder: f(self.builder),
            method: self.method,
            url: self.url,
        }
    }

    pub fn headers(self, headers: HeaderMap) -> Self {
        self.map(|builder| builder.headers(headers))
    }

    pub fn header<K, V>(self, key: K, value: V) -> Self
    where
        HeaderName: TryFrom<K>,
        <HeaderName as TryFrom<K>>::Error: Into<HttpError>,
        HeaderValue: TryFrom<V>,
        <HeaderValue as TryFrom<V>>::Error: Into<HttpError>,
    {
        self.map(|builder| builder.header(key, value))
    }

    pub fn bearer_auth<T>(self, token: T) -> Self
    where
        T: Display,
    {
        self.map(|builder| builder.bearer_auth(token))
    }

    pub fn timeout(self, timeout: Duration) -> Self {
        self.map(|builder| builder.timeout(timeout))
    }

    pub fn json<T>(self, value: &T) -> Self
    where
        T: ?Sized + Serialize,
    {
        self.map(|builder| builder.json(value))
    }

    pub fn body<B>(self, body: B) -> Self
    where
        B: Into<reqwest::Body>,
    {
        self.map(|builder| builder.body(body))
    }

    pub async fn send(self) -> Result<Response, reqwest::Error> {
        let headers = trace_headers();
        // Build the final reqwest::Request before sending so debug logging can serialize the exact
        // provider-bound request payload after trace headers have been attached, without touching
        // the response body path.
        let (client, request_result) = self.builder.headers(headers).build_split();
        let request = request_result?;
        #[cfg(debug_assertions)]
        persist_debug_http_request_log(&request);

        match client.execute(request).await {
            Ok(response) => {
                tracing::debug!(
                    method = %self.method,
                    url = %self.url,
                    status = %response.status(),
                    headers = ?response.headers(),
                    version = ?response.version(),
                    "Request completed"
                );

                Ok(response)
            }
            Err(error) => {
                let status = error.status();
                tracing::debug!(
                    method = %self.method,
                    url = %self.url,
                    status = status.map(|s| s.as_u16()),
                    error = %error,
                    "Request failed"
                );
                Err(error)
            }
        }
    }
}

#[cfg(any(debug_assertions, test))]
#[derive(Serialize)]
struct DebugHttpRequestLogEntry {
    recorded_at: String,
    method: String,
    url: String,
    headers: BTreeMap<String, Vec<String>>,
    body: Option<serde_json::Value>,
}

#[cfg(any(debug_assertions, test))]
impl DebugHttpRequestLogEntry {
    fn from_request(request: &Request) -> Self {
        Self {
            // Keep both the filename and payload timestamp human-readable so developers can line up
            // a request with CLI behavior without opening multiple tools or translating epochs.
            recorded_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            method: request.method().to_string(),
            url: request.url().to_string(),
            headers: collect_request_headers(request),
            body: collect_request_body(request),
        }
    }
}

#[cfg(any(debug_assertions, test))]
fn collect_request_headers(request: &Request) -> BTreeMap<String, Vec<String>> {
    let mut headers = BTreeMap::<String, Vec<String>>::new();
    for (name, value) in request.headers() {
        let key = name.as_str().to_string();
        headers
            .entry(key.clone())
            .or_default()
            .push(sanitize_header_value(&key, value));
    }
    headers
}

#[cfg(any(debug_assertions, test))]
fn sanitize_header_value(name: &str, value: &HeaderValue) -> String {
    if is_sensitive_header(name) {
        return "<redacted>".to_string();
    }

    value.to_str().map(ToString::to_string).unwrap_or_else(|_| {
        serde_json::json!({
            "encoding": "base64",
            "value": encode_base64(value.as_bytes())
        })
        .to_string()
    })
}

#[cfg(any(debug_assertions, test))]
fn is_sensitive_header(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        "authorization" | "proxy-authorization" | "cookie" | "set-cookie" | "x-api-key"
    )
}

#[cfg(any(debug_assertions, test))]
fn collect_request_body(request: &Request) -> Option<serde_json::Value> {
    let bytes = request.body()?.as_bytes()?;

    if let Ok(mut json_body) = serde_json::from_slice::<serde_json::Value>(bytes) {
        redact_sensitive_json_fields(&mut json_body);
        return Some(json_body);
    }

    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(serde_json::Value::String(text.to_string()));
    }

    Some(serde_json::json!({
        "encoding": "base64",
        "value": encode_base64(bytes)
    }))
}

#[cfg(any(debug_assertions, test))]
fn encode_base64(bytes: &[u8]) -> String {
    use base64::Engine as _;

    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[cfg(any(debug_assertions, test))]
fn redact_sensitive_json_fields(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, nested) in map.iter_mut() {
                if is_sensitive_json_key(key) {
                    *nested = serde_json::Value::String("<redacted>".to_string());
                } else {
                    redact_sensitive_json_fields(nested);
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                redact_sensitive_json_fields(item);
            }
        }
        _ => {}
    }
}

#[cfg(any(debug_assertions, test))]
fn is_sensitive_json_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase();
    matches!(
        normalized.as_str(),
        "password"
            | "token"
            | "access_token"
            | "refresh_token"
            | "api_key"
            | "apikey"
            | "authorization"
            | "secret"
            | "client_secret"
    ) || normalized.ends_with("_password")
        || normalized.ends_with("_token")
        || normalized.ends_with("_secret")
        || normalized.ends_with("_api_key")
}

#[cfg(debug_assertions)]
fn persist_debug_http_request_log(request: &Request) {
    let entry = DebugHttpRequestLogEntry::from_request(request);
    if let Err(error) = write_debug_http_request_log(&entry) {
        tracing::debug!(error = %error, "failed to persist debug http request log");
    }
}

#[cfg(debug_assertions)]
fn write_debug_http_request_log(entry: &DebugHttpRequestLogEntry) -> std::io::Result<()> {
    let log_dir = resolve_debug_http_log_dir()?;
    fs::create_dir_all(&log_dir)?;

    let file_name = format!(
        "{}-{}.json",
        // Use a Windows-safe timestamp format while preserving lexical sort order so pruning can
        // reliably drop the oldest request files without inspecting file metadata.
        Utc::now().format("%Y%m%dT%H%M%S%.3fZ"),
        Uuid::new_v4()
    );
    let log_path = log_dir.join(file_name);
    let payload = serde_json::to_vec_pretty(entry)
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    fs::write(log_path, payload)?;
    prune_http_request_logs(&log_dir, DEBUG_HTTP_REQUEST_LOG_LIMIT)
}

#[cfg(debug_assertions)]
fn resolve_debug_http_log_dir() -> std::io::Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    let workspace_root = cwd
        .ancestors()
        .find(|candidate| {
            candidate.join(".sirix").is_dir()
                || candidate.join(".git").is_dir()
                || candidate.join(".git").is_file()
        })
        .map(Path::to_path_buf)
        .unwrap_or(cwd);
    Ok(workspace_root.join(".sirix").join("log").join("http"))
}

#[cfg(debug_assertions)]
fn prune_http_request_logs(log_dir: &Path, keep_latest: usize) -> std::io::Result<()> {
    let mut files = fs::read_dir(log_dir)?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let file_type = entry.file_type().ok()?;
            file_type.is_file().then_some(entry.path())
        })
        .collect::<Vec<_>>();

    if files.len() <= keep_latest {
        return Ok(());
    }

    files.sort();
    let remove_count = files.len().saturating_sub(keep_latest);
    for path in files.into_iter().take(remove_count) {
        fs::remove_file(path)?;
    }
    Ok(())
}

struct HeaderMapInjector<'a>(&'a mut HeaderMap);

impl<'a> Injector for HeaderMapInjector<'a> {
    fn set(&mut self, key: &str, value: String) {
        if let (Ok(name), Ok(val)) = (
            HeaderName::from_bytes(key.as_bytes()),
            HeaderValue::from_str(&value),
        ) {
            self.0.insert(name, val);
        }
    }
}

fn trace_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    global::get_text_map_propagator(|prop| {
        prop.inject_context(
            &Span::current().context(),
            &mut HeaderMapInjector(&mut headers),
        );
    });
    headers
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::propagation::Extractor;
    use opentelemetry::propagation::TextMapPropagator;
    use opentelemetry::trace::TraceContextExt;
    use opentelemetry::trace::TracerProvider;
    use opentelemetry_sdk::propagation::TraceContextPropagator;
    use opentelemetry_sdk::trace::SdkTracerProvider;
    use tempfile::tempdir;
    use tracing::trace_span;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    #[test]
    fn inject_trace_headers_uses_current_span_context() {
        global::set_text_map_propagator(TraceContextPropagator::new());

        let provider = SdkTracerProvider::builder().build();
        let tracer = provider.tracer("test-tracer");
        let subscriber =
            tracing_subscriber::registry().with(tracing_opentelemetry::layer().with_tracer(tracer));
        let _guard = subscriber.set_default();

        let span = trace_span!("client_request");
        let _entered = span.enter();
        let span_context = span.context().span().span_context().clone();

        let headers = trace_headers();

        let extractor = HeaderMapExtractor(&headers);
        let extracted = TraceContextPropagator::new().extract(&extractor);
        let extracted_span = extracted.span();
        let extracted_context = extracted_span.span_context();

        assert!(extracted_context.is_valid());
        assert_eq!(extracted_context.trace_id(), span_context.trace_id());
        assert_eq!(extracted_context.span_id(), span_context.span_id());
    }

    #[test]
    fn collect_request_body_redacts_sensitive_json_fields() {
        let request = reqwest::Client::new()
            .post("https://api.openai.com/v1/responses")
            .json(&serde_json::json!({
                "model": "gpt-5.4",
                "password": "super-secret",
                "nested": {
                    "api_key": "sensitive-key",
                    "safe": "visible"
                }
            }))
            .build()
            .expect("build request");

        let body = collect_request_body(&request).expect("request body should be captured");

        assert_eq!(body["password"], "<redacted>");
        assert_eq!(body["nested"]["api_key"], "<redacted>");
        assert_eq!(body["nested"]["safe"], "visible");
    }

    #[cfg(debug_assertions)]
    #[test]
    fn prune_http_request_logs_keeps_newest_fifty_files() {
        let temp = tempdir().expect("create temp dir");
        let log_dir = temp.path().join("http");
        fs::create_dir_all(&log_dir).expect("create log dir");

        for index in 0..60 {
            let path = log_dir.join(format!("20260414T120000.{index:03}Z-{index:03}.json"));
            fs::write(path, b"{}").expect("write log fixture");
        }

        prune_http_request_logs(&log_dir, 50).expect("prune logs");

        let mut remaining = fs::read_dir(&log_dir)
            .expect("read log dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        remaining.sort();

        assert_eq!(remaining.len(), 50);
        assert_eq!(
            remaining.first().expect("first log"),
            "20260414T120000.010Z-010.json"
        );
        assert_eq!(
            remaining.last().expect("last log"),
            "20260414T120000.059Z-059.json"
        );
    }

    struct HeaderMapExtractor<'a>(&'a HeaderMap);

    impl<'a> Extractor for HeaderMapExtractor<'a> {
        fn get(&self, key: &str) -> Option<&str> {
            self.0.get(key).and_then(|value| value.to_str().ok())
        }

        fn keys(&self) -> Vec<&str> {
            self.0.keys().map(HeaderName::as_str).collect()
        }
    }
}
