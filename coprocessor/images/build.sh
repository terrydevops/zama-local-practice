#!/bin/bash
# Build the images this repo needs from the fhevm checkout and optionally load them into kind.
#   ./build.sh [load] [image ...]
# Images: tfhe-worker sns-worker zkproof-worker host-listener gw-listener transaction-sender (Dockerfile, Rust workspace)
#         host-contracts (host-contracts.Dockerfile, npm workspace), gateway-contracts (gateway-contracts.Dockerfile)
#         kms-core (kms-core.Dockerfile, the kms checkout next to fhevm)
#         kms-connector-gw-listener kms-connector-kms-worker kms-connector-tx-sender kms-connector-db-migration (kms-connector.Dockerfile)
# FHEVM_DIR overrides the checkout location (default: ../zama-ai-repos/fhevm next to this repo).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
KMS_DIR=${KMS_DIR:-$ROOT/../zama-ai-repos/kms}
TAG=${TAG:-dev}
CLUSTER=${KIND_CLUSTER:-zama-practice}
LOAD=false
if [ "${1:-}" = load ]; then LOAD=true; shift; fi
RUST_IMAGES="tfhe-worker sns-worker zkproof-worker host-listener gw-listener transaction-sender"
CONNECTOR_IMAGES="kms-connector-gw-listener kms-connector-kms-worker kms-connector-tx-sender kms-connector-db-migration"
IMAGES=${*:-$RUST_IMAGES host-contracts gateway-contracts kms-core $CONNECTOR_IMAGES}

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

build_gateway_contracts() {
  tar -C "$FHEVM_DIR" -c --exclude=node_modules --exclude=artifacts --exclude=cache --exclude=typechain-types \
      --exclude=addresses --exclude=.git \
      gateway-contracts/package.json gateway-contracts/package-lock.json gateway-contracts/hardhat.config.ts \
      gateway-contracts/tsconfig.json gateway-contracts/contracts gateway-contracts/tasks > "$CTX/gc.tar"
  tar -C "$HERE" -r -f "$CTX/gc.tar" gateway-contracts.Dockerfile
  echo "== local/gateway-contracts:$TAG (fhevm ${have:0:8})"
  docker build -f gateway-contracts.Dockerfile -t "local/gateway-contracts:$TAG" \
    --label "fhevm.commit=$have" - < "$CTX/gc.tar"
}

build_kms_core() {
  kms_have=$(git -C "$KMS_DIR" rev-parse HEAD)
  tar -C "$KMS_DIR" -c --exclude=target --exclude=.git --exclude=node_modules . > "$CTX/kms.tar"
  tar -C "$HERE" -r -f "$CTX/kms.tar" kms-core.Dockerfile
  echo "== local/kms-core:$TAG (kms ${kms_have:0:8})"
  docker build -f kms-core.Dockerfile -t "local/kms-core:$TAG" --label "kms.commit=$kms_have" - < "$CTX/kms.tar"
}

build_kms_connector() {
  tar -C "$FHEVM_DIR" -c --exclude=target --exclude=node_modules --exclude=.git \
      kms-connector gateway-contracts/rust_bindings host-contracts/rust_bindings shared > "$CTX/kc.tar"
  tar -C "$HERE" -r -f "$CTX/kc.tar" kms-connector.Dockerfile
  for t in "$@"; do
    echo "== local/kms-connector-$t:$TAG (fhevm ${have:0:8})"
    docker build -f kms-connector.Dockerfile --target "$t" -t "local/kms-connector-$t:$TAG" \
      --label "fhevm.commit=$have" - < "$CTX/kc.tar"
  done
}

rust=()
for i in $IMAGES; do
  case " $RUST_IMAGES " in *" $i "*) rust+=("$i") ;; esac
done
[ ${#rust[@]} -gt 0 ] && build_rust "${rust[@]}"
case " $IMAGES " in *" host-contracts "*) build_host_contracts ;; esac
case " $IMAGES " in *" gateway-contracts "*) build_gateway_contracts ;; esac
case " $IMAGES " in *" kms-core "*) build_kms_core ;; esac
conn=()
for i in $IMAGES; do
  case " $CONNECTOR_IMAGES " in *" $i "*) conn+=("${i#kms-connector-}") ;; esac
done
[ ${#conn[@]} -gt 0 ] && build_kms_connector "${conn[@]}"
docker images 'local/*' --format '{{.Repository}}:{{.Tag}}  {{.Size}}'

if $LOAD; then
  for i in $IMAGES; do kind load docker-image "local/$i:$TAG" --name "$CLUSTER"; done
fi
