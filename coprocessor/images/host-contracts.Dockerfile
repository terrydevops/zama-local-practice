# host-contracts image for the contracts chart deploy Job. Follows the upstream
# host-contracts/Dockerfile with a public Node base image (the upstream base is private).
# Context = tar streamed by build.sh from the fhevm checkout root (npm workspace).
ARG NODE_IMAGE=node:22.23-alpine
FROM ${NODE_IMAGE} AS prod
SHELL ["/bin/ash", "-o", "pipefail", "-c"]
USER root
RUN apk add --no-cache bash curl git jq kubectl python3 python3-dev make g++ gcc nodejs-dev \
    && ln -sf /usr/bin/gcc /usr/bin/cc \
    && addgroup -g 10001 fhevm && adduser -D -u 10000 -G fhevm -h /home/fhevm fhevm
RUN npm install -g pnpm@9
ARG FOUNDRY_VERSION=v1.7.1
ARG TARGETARCH
RUN case "$TARGETARCH" in arm64) fa=arm64 ;; *) fa=amd64 ;; esac \
    && curl -fsSL "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_alpine_${fa}.tar.gz" \
      | tar -xz -C /usr/local/bin forge cast anvil chisel
RUN mkdir -p /app /install/host-contracts && chown -R fhevm:fhevm /app /install /home/fhevm
USER 10000:10001
WORKDIR /install
COPY --chown=fhevm:fhevm package.json package-lock.json ./
COPY --chown=fhevm:fhevm host-contracts/package.json host-contracts/
RUN npm ci --workspace=host-contracts --include-workspace-root=false && npm prune
WORKDIR /app
RUN mv /install/host-contracts/* . && mv /install/node_modules ./node_modules
COPY --chown=fhevm:fhevm host-contracts/*.ts host-contracts/tsconfig.json ./
COPY --chown=fhevm:fhevm host-contracts/contracts ./contracts/
COPY --chown=fhevm:fhevm host-contracts/tasks ./tasks/
COPY --chown=fhevm:fhevm host-contracts/lib ./lib/
COPY --chown=fhevm:fhevm host-contracts/examples/bridge/mocks ./examples/bridge/mocks/
COPY --chown=fhevm:fhevm host-contracts/lz-wiring ./lz-wiring/
COPY --chown=fhevm:fhevm host-contracts/lz_wiring_from_eoa_owner.sh ./lz_wiring_from_eoa_owner.sh
RUN mkdir -p ./addresses
# Pre-compile the proxy contracts so the deploy Job starts fast
RUN npx hardhat clean && npx hardhat compile:specific --contract contracts/emptyProxyACL
ENTRYPOINT ["/bin/bash", "-c"]
