# coprocessor-demo image. Context = tar streamed by build.sh from the parent of both repos so
# that the contracts' relative remappings (../../../../zama-ai-repos/fhevm/...) resolve.
ARG RUST_IMAGE=rust:1.97-trixie
ARG FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:v1.3.5

# the demo contracts against the FHE library of the checkout
FROM ${FOUNDRY_IMAGE} AS sol
WORKDIR /w
COPY --chown=foundry:foundry zama-ai-repos/fhevm/library-solidity ./zama-ai-repos/fhevm/library-solidity
COPY --chown=foundry:foundry zama-ai-repos/fhevm/host-contracts ./zama-ai-repos/fhevm/host-contracts
COPY --chown=foundry:foundry zama-local-practice/coprocessor/demo/contracts ./zama-local-practice/coprocessor/demo/contracts
WORKDIR /w/zama-local-practice/coprocessor/demo/contracts
RUN ./build.sh

FROM ${RUST_IMAGE} AS builder
WORKDIR /w
COPY zama-local-practice ./zama-local-practice
WORKDIR /w/zama-local-practice/coprocessor/demo
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/w/zama-local-practice/coprocessor/demo/target,sharing=locked \
    cargo build --release && cp target/release/coprocessor_demo /coprocessor_demo

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -s /usr/sbin/nologin fhevm
USER 10001
COPY --from=builder /coprocessor_demo /usr/local/bin/coprocessor_demo
COPY --from=sol /w/zama-local-practice/coprocessor/demo/contracts/out/Add.sol/Add.json /app/Add.json
COPY --from=sol /w/zama-local-practice/coprocessor/demo/contracts/out/PracticeToken.sol/PracticeToken.json /app/PracticeToken.json
ENTRYPOINT ["coprocessor_demo"]
