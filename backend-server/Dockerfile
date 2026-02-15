FROM rust:1.82-slim AS builder
WORKDIR /app
COPY Cargo.toml ./
COPY Cargo.lock ./
COPY migrations ./migrations
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
WORKDIR /app
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/backend-server /usr/local/bin/backend-server
COPY config ./config
EXPOSE 8080
CMD ["backend-server"]
