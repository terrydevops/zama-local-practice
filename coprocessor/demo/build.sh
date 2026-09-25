#!/bin/bash
# Build local/coprocessor-demo:dev and optionally load it into kind.
#   ./build.sh [load]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)            # zama-local-practice
PARENT=$(cd "$ROOT/.." && pwd)             # holds zama-local-practice and zama-ai-repos
FHEVM_DIR=${FHEVM_DIR:-$PARENT/zama-ai-repos/fhevm}
TAG=${TAG:-dev}
CLUSTER=${KIND_CLUSTER:-zama-practice}
[ "$FHEVM_DIR" = "$PARENT/zama-ai-repos/fhevm" ] || { echo "fhevm checkout must be at $PARENT/zama-ai-repos/fhevm for the image build" >&2; exit 1; }

export DOCKER_BUILDKIT=1
CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT
tar -C "$PARENT" -c --exclude=target --exclude=node_modules --exclude=.git \
    --exclude=coprocessor/demo/contracts/out --exclude=coprocessor/demo/contracts/cache \
    zama-ai-repos/fhevm/library-solidity/lib zama-ai-repos/fhevm/library-solidity/config \
    zama-ai-repos/fhevm/host-contracts/lib zama-ai-repos/fhevm/host-contracts/contracts/shared/FheType.sol \
    zama-ai-repos/fhevm/host-contracts/examples/EncryptedERC20.sol \
    zama-local-practice/coprocessor/demo > "$CTX/ctx.tar"
# the npm dependencies the contracts import (node_modules is excluded above)
tar -C "$PARENT" -r -f "$CTX/ctx.tar" zama-ai-repos/fhevm/library-solidity/node_modules/encrypted-types \
    zama-ai-repos/fhevm/host-contracts/node_modules/@openzeppelin/contracts/access \
    zama-ai-repos/fhevm/host-contracts/node_modules/@openzeppelin/contracts/utils/Context.sol
tar -C "$HERE" -r -f "$CTX/ctx.tar" Dockerfile
docker build -f Dockerfile -t "local/coprocessor-demo:$TAG" - < "$CTX/ctx.tar"
docker images 'local/coprocessor-demo' --format '{{.Repository}}:{{.Tag}}  {{.Size}}'
if [ "${1:-}" = "load" ]; then
  kind load docker-image "local/coprocessor-demo:$TAG" --name "$CLUSTER"
fi
