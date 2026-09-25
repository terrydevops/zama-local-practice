# Local-practice build of the coprocessor workers.
# Mirrors fhevm/coprocessor/fhevm-engine/Dockerfile.workspace but uses only
# public base images (rust:* builder, debian:trixie-slim runtime).
#
#   docker build -f Dockerfile --target tfhe-worker   -t local/tfhe-worker:dev   <fhevm-engine dir>
#   docker build -f Dockerfile --target sns-worker    -t local/sns-worker:dev    <fhevm-engine dir>
#   docker build -f Dockerfile --target zkproof-worker -t local/zkproof-worker:dev <fhevm-engine dir>
#
# Build context = a tar of fhevm/{coprocessor/proto,coprocessor/fhevm-engine,listener}
# without target/ dirs, streamed on stdin by build.sh.

ARG RUST_IMAGE=rust:1.97-trixie

# ---------------------------------------------------------------- builder
FROM ${RUST_IMAGE} AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      protobuf-compiler pkg-config libssl-dev clang \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# context = tar of the fhevm repo subset (see build.sh): coprocessor/{proto,fhevm-engine}
# and listener/ must keep their relative layout because host-listener depends on
# ../../../listener/crates/*.
COPY coprocessor/proto ./coprocessor/proto
COPY listener ./listener
COPY shared ./shared
COPY host-contracts/rust_bindings ./host-contracts/rust_bindings
COPY gateway-contracts/rust_bindings ./gateway-contracts/rust_bindings
COPY coprocessor/fhevm-engine ./coprocessor/fhevm-engine
WORKDIR /src/coprocessor/fhevm-engine
ENV SQLX_OFFLINE=true
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/coprocessor/fhevm-engine/target,sharing=locked \
    cargo build --release --bin tfhe_worker --bin sns_worker --bin zkproof_worker --bin host_listener --bin gw_listener --bin transaction_sender \
    && mkdir -p /out \
    && cp target/release/tfhe_worker target/release/sns_worker target/release/zkproof_worker target/release/host_listener target/release/gw_listener target/release/transaction_sender /out/

# ---------------------------------------------------------------- runtime
FROM debian:trixie-slim AS runtime-base
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -s /usr/sbin/nologin fhevm
USER 10001

FROM runtime-base AS tfhe-worker
COPY --from=builder /out/tfhe_worker /usr/local/bin/tfhe_worker
ENTRYPOINT ["tfhe_worker"]

FROM runtime-base AS sns-worker
COPY --from=builder /out/sns_worker /usr/local/bin/sns_worker
ENTRYPOINT ["sns_worker"]

FROM runtime-base AS zkproof-worker
COPY --from=builder /out/zkproof_worker /usr/local/bin/zkproof_worker
ENTRYPOINT ["zkproof_worker"]

FROM runtime-base AS host-listener
COPY --from=builder /out/host_listener /usr/local/bin/host_listener
ENTRYPOINT ["host_listener"]

FROM runtime-base AS gw-listener
COPY --from=builder /out/gw_listener /usr/local/bin/gw_listener
ENTRYPOINT ["gw_listener"]

FROM runtime-base AS transaction-sender
COPY --from=builder /out/transaction_sender /usr/local/bin/transaction_sender
ENTRYPOINT ["transaction_sender"]
