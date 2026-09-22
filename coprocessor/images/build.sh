#!/bin/bash
# Build the three worker images from the fhevm checkout and optionally load them into kind.
#   ./build.sh          build
#   ./build.sh load     build + kind load
# FHEVM_DIR overrides the checkout location (default: ../zama-ai-repos/fhevm next to this repo).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
TAG=${TAG:-dev}
CLUSTER=${KIND_CLUSTER:-zama-practice}

want=$(cat "$ROOT/.fhevm-ref")
have=$(git -C "$FHEVM_DIR" rev-parse HEAD)
if [ "$want" != "$have" ]; then
  echo "warning: fhevm checkout is at ${have:0:8}, .fhevm-ref says ${want:0:8}" >&2
fi

export DOCKER_BUILDKIT=1
# Context: the workspace plus every out-of-tree path dependency, minus build artifacts.
CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT
tar -C "$FHEVM_DIR" -c --exclude=target --exclude=node_modules --exclude=.git --exclude=fhevm-keys \
    coprocessor/proto coprocessor/fhevm-engine listener shared \
    host-contracts/rust_bindings gateway-contracts/rust_bindings > "$CTX/ctx.tar"
tar -C "$HERE" -r -f "$CTX/ctx.tar" Dockerfile

for t in tfhe-worker sns-worker zkproof-worker host-listener; do
  echo "== local/$t:$TAG (fhevm ${have:0:8})"
  docker build -f Dockerfile --target "$t" -t "local/$t:$TAG" \
    --label "fhevm.commit=$have" - < "$CTX/ctx.tar"
done
docker images 'local/*' --format '{{.Repository}}:{{.Tag}}  {{.Size}}'

if [ "${1:-}" = "load" ]; then
  for t in tfhe-worker sns-worker zkproof-worker host-listener; do
    kind load docker-image "local/$t:$TAG" --name "$CLUSTER"
  done
fi
