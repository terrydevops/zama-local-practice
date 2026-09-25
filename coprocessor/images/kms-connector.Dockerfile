# kms-connector components (gw-listener, kms-worker, tx-sender) and the connector database
# migration, built from the fhevm checkout. Upstream builds on private base images; this uses
# the public Rust, Debian and Postgres images. Context = tar streamed by build.sh from the
# fhevm root: kms-connector plus the sibling path dependencies it imports.
ARG RUST_IMAGE=rust:1.97-trixie

FROM ${RUST_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler pkg-config libssl-dev clang cmake \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
# connector-utils embeds `git describe` at compile time; the tar context has no repository
RUN git init -q . && git -c user.name=build -c user.email=build@localhost add -A >/dev/null \
    && git -c user.name=build -c user.email=build@localhost commit -q -m build \
    && git tag v0.0.0-local
WORKDIR /src/kms-connector
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/kms-connector/target,sharing=locked \
    cargo build --release --locked --bin gw-listener --bin kms-worker --bin tx-sender \
    && mkdir -p /out && cp target/release/gw-listener target/release/kms-worker target/release/tx-sender /out/ \
    && cargo install sqlx-cli --version 0.8.6 --no-default-features --features postgres --locked --root /out/sqlx

FROM debian:trixie-slim AS runtime-base
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -s /usr/sbin/nologin fhevm
USER 10001

FROM runtime-base AS gw-listener
COPY --from=builder /out/gw-listener /app/kms-connector/bin/gw-listener
ENTRYPOINT ["/app/kms-connector/bin/gw-listener", "start"]

FROM runtime-base AS kms-worker
COPY --from=builder /out/kms-worker /app/kms-connector/bin/kms-worker
ENTRYPOINT ["/app/kms-connector/bin/kms-worker", "start"]

FROM runtime-base AS tx-sender
COPY --from=builder /out/tx-sender /app/kms-connector/bin/tx-sender
ENTRYPOINT ["/app/kms-connector/bin/tx-sender", "start"]

# sqlx migrations for the connector database, run once like the upstream db-migration image
FROM postgres:17 AS db-migration
COPY --from=builder /out/sqlx/bin/sqlx /usr/local/bin/sqlx
COPY kms-connector/connector-db/init_db.sh /init_db.sh
COPY kms-connector/connector-db/migrations /migrations
USER postgres
ENTRYPOINT ["/bin/bash", "/init_db.sh"]
