#!/bin/bash
# Build the images this repo needs from the fhevm checkout and optionally load them into kind.
#   ./build.sh [load] [image ...]
# Images: tfhe-worker sns-worker zkproof-worker host-listener (Dockerfile, Rust workspace)
#         host-contracts (host-contracts.Dockerfile, npm workspace)
# FHEVM_DIR overrides the checkout location (default: ../zama-ai-repos/fhevm next to this repo).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
TAG=${TAG:-dev}
CLUSTER=${KIND_CLUSTER:-zama-practice}
LOAD=false
if [ "${1:-}" = load ]; then LOAD=true; shift; fi
RUST_IMAGES="tfhe-worker sns-worker zkproof-worker host-listener"
IMAGES=${*:-$RUST_IMAGES host-contracts}

want=$(cat "$ROOT/.fhevm-ref")
have=$(git -C "$FHEVM_DIR" rev-parse HEAD)
if [ "$want" != "$have" ]; then
  echo "warning: fhevm checkout is at ${have:0:8}, .fhevm-ref says ${want:0:8}" >&2
fi

export DOCKER_BUILDKIT=1
CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT

build_rust() {
  # Context: the workspace plus every out-of-tree path dependency, minus build artifacts.
  tar -C "$FHEVM_DIR" -c --exclude=target --exclude=node_modules --exclude=.git --exclude=fhevm-keys \
      coprocessor/proto coprocessor/fhevm-engine listener shared \
      host-contracts/rust_bindings gateway-contracts/rust_bindings > "$CTX/rust.tar"
  tar -C "$HERE" -r -f "$CTX/rust.tar" Dockerfile
  for t in "$@"; do
    echo "== local/$t:$TAG (fhevm ${have:0:8})"
    docker build -f Dockerfile --target "$t" -t "local/$t:$TAG" \
      --label "fhevm.commit=$have" - < "$CTX/rust.tar"
  done
}

build_host_contracts() {
  tar -C "$FHEVM_DIR" -c --exclude=node_modules --exclude=artifacts --exclude=cache --exclude=typechain-types \
      --exclude=addresses --exclude=.git \
      package.json package-lock.json \
      host-contracts/package.json host-contracts/tsconfig.json host-contracts/hardhat.config.ts host-contracts/CustomProvider.ts \
      host-contracts/contracts host-contracts/tasks host-contracts/lib host-contracts/examples/bridge/mocks \
      host-contracts/lz-wiring host-contracts/lz_wiring_from_eoa_owner.sh > "$CTX/hc.tar"
  tar -C "$HERE" -r -f "$CTX/hc.tar" host-contracts.Dockerfile
  echo "== local/host-contracts:$TAG (fhevm ${have:0:8})"
  docker build -f host-contracts.Dockerfile -t "local/host-contracts:$TAG" \
    --label "fhevm.commit=$have" - < "$CTX/hc.tar"
}

rust=()
for i in $IMAGES; do
  case " $RUST_IMAGES " in *" $i "*) rust+=("$i") ;; esac
done
[ ${#rust[@]} -gt 0 ] && build_rust "${rust[@]}"
case " $IMAGES " in *" host-contracts "*) build_host_contracts ;; esac
docker images 'local/*' --format '{{.Repository}}:{{.Tag}}  {{.Size}}'

if $LOAD; then
  for i in $IMAGES; do kind load docker-image "local/$i:$TAG" --name "$CLUSTER"; done
fi
