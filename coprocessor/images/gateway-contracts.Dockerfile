# gateway-contracts image for the contracts chart deploy Job. Follows the upstream
# gateway-contracts/Dockerfile with a public Node base image (the upstream base is private).
# Context = tar streamed by build.sh from the fhevm checkout root.
ARG NODE_IMAGE=node:22.23-alpine
FROM ${NODE_IMAGE} AS prod
SHELL ["/bin/ash", "-o", "pipefail", "-c"]
USER root
RUN apk add --no-cache bash curl git jq kubectl python3 python3-dev make g++ gcc nodejs-dev \
    && ln -sf /usr/bin/gcc /usr/bin/cc \
    && addgroup -g 10001 fhevm && adduser -D -u 10000 -G fhevm -h /home/fhevm fhevm
ARG FOUNDRY_VERSION=v1.7.1
ARG TARGETARCH
RUN case "$TARGETARCH" in arm64) fa=arm64 ;; *) fa=amd64 ;; esac \
    && curl -fsSL "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_alpine_${fa}.tar.gz" \
      | tar -xz -C /usr/local/bin forge cast anvil chisel
WORKDIR /app
RUN chown -R fhevm:fhevm /home/fhevm /app
USER 10000:10001
COPY --chown=fhevm:fhevm gateway-contracts/package.json gateway-contracts/package-lock.json ./
RUN npm ci && npm prune
COPY --chown=fhevm:fhevm gateway-contracts/hardhat.config.ts gateway-contracts/tsconfig.json ./
COPY --chown=fhevm:fhevm gateway-contracts/contracts ./contracts/
COPY --chown=fhevm:fhevm gateway-contracts/tasks ./tasks/
RUN mkdir -p ./addresses
# Pre-compile the proxy and mock contracts so the deploy Job starts fast
RUN npx hardhat clean \
    && npx hardhat compile:specific --contract contracts/emptyProxyGatewayConfig \
    && npx hardhat compile:specific --contract contracts/mocks
ENTRYPOINT ["/bin/bash", "-c"]
