#!/bin/bash
# Run the on-chain add check from the laptop: contract built with forge here, anvil reached
# through a port-forward, addresses and the sender key read from the cluster, database via
# db-url.sh. X and Y override the two numbers.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
CTX=${KUBE_CONTEXT:-kind-zama-practice}
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:$PATH"
PORT=${ANVIL_PORT:-18545}
(cd "$HERE/contracts" && forge build >/dev/null)
cm() { kubectl --context "$CTX" -n coproc get configmap eth-sc-addresses -o "jsonpath={.data.$1}"; }
export ACL_ADDRESS; ACL_ADDRESS=$(cm 'acl\.address')
export FHEVM_EXECUTOR_ADDRESS; FHEVM_EXECUTOR_ADDRESS=$(cm 'fhevm_executor\.address')
export KMS_VERIFIER_ADDRESS; KMS_VERIFIER_ADDRESS=$(cm 'kms_verifier\.address')
export PRIVATE_KEY; PRIVATE_KEY=$(kubectl --context "$CTX" -n coproc get secret demo-sender -o 'jsonpath={.data.private-key}' | base64 -d)
export DATABASE_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
export RPC_URL=http://127.0.0.1:$PORT
export ADD_ARTIFACT=$HERE/contracts/out/Add.sol/Add.json
export SQLX_OFFLINE=true
export SQLX_OFFLINE_DIR=$FHEVM_DIR/coprocessor/fhevm-engine/.sqlx
kubectl --context "$CTX" -n infra port-forward svc/anvil "$PORT:8545" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT; sleep 2
cargo run --release --quiet --manifest-path "$HERE/Cargo.toml"
