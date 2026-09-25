# KMS core (kms-server + kms-gen-keys) built from the kms checkout with the "insecure" feature:
# the development flavour that runs a centralized KMS without an enclave and without TLS,
# the same one the upstream e2e stack uses (core-service-insecure). Upstream builds this on
# private base images; this uses the public Rust and Debian images like the worker images.
# Context = tar of the kms checkout streamed by build.sh.
ARG RUST_IMAGE=rust:1.97-trixie

FROM ${RUST_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler pkg-config libssl-dev clang cmake \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release --locked -p kms --bin kms-server --bin kms-gen-keys --features insecure \
    && mkdir -p /out && cp target/release/kms-server target/release/kms-gen-keys /out/

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10002 -m -d /app/kms/core/service -s /usr/sbin/nologin kms
USER 10002
WORKDIR /app/kms/core/service
COPY --from=builder /out/kms-server /out/kms-gen-keys /usr/local/bin/
ENTRYPOINT ["kms-server"]
