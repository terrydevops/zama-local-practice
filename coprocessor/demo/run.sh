#!/bin/bash
# Run a demo scenario from the laptop: contracts built with forge here, both anvil chains
# reached through port-forwards, addresses and the sender key read from the cluster,
# database via db-url.sh.
#   ./run.sh [add|transfer]    X/Y and MINT/AMOUNT/TOO_MUCH override the numbers
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
PORT=${ANVIL_PORT:-18545}
GW_PORT=${ANVIL_GATEWAY_PORT:-18546}
"$HERE/contracts/build.sh" >/dev/null
cm() { kubectl --context "$CTX" -n coproc get configmap "$1" -o "jsonpath={.data.$2}"; }
export ACL_ADDRESS; ACL_ADDRESS=$(cm eth-sc-addresses 'acl\.address')
export FHEVM_EXECUTOR_ADDRESS; FHEVM_EXECUTOR_ADDRESS=$(cm eth-sc-addresses 'fhevm_executor\.address')
export KMS_VERIFIER_ADDRESS; KMS_VERIFIER_ADDRESS=$(cm eth-sc-addresses 'kms_verifier\.address')
export DECRYPTION_ADDRESS; DECRYPTION_ADDRESS=$(cm gw-sc-addresses 'decryption\.address')
export PROTOCOL_PAYMENT_ADDRESS; PROTOCOL_PAYMENT_ADDRESS=$(cm gw-sc-addresses 'protocol_payment\.address')
export CIPHERTEXT_COMMITS_ADDRESS; CIPHERTEXT_COMMITS_ADDRESS=$(cm gw-sc-addresses 'ciphertext_commits\.address')
export ZAMA_OFT_ADDRESS; ZAMA_OFT_ADDRESS=$(grep -oE 'ZAMA_OFT_ADDRESS, value: "0x[0-9a-fA-F]+"' "$ROOT/coprocessor/gateway-contracts/values.yaml" | grep -oE '0x[0-9a-fA-F]+')
export PRIVATE_KEY; PRIVATE_KEY=$(kubectl --context "$CTX" -n coproc get secret demo-sender -o 'jsonpath={.data.private-key}' | base64 -d)
export DATABASE_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
export RPC_URL=http://127.0.0.1:$PORT
export GATEWAY_RPC_URL=http://127.0.0.1:$GW_PORT
export ADD_ARTIFACT=$HERE/contracts/out/Add.sol/Add.json
export TOKEN_ARTIFACT=$HERE/contracts/out/PracticeToken.sol/PracticeToken.json
export SCENARIO=${1:-${SCENARIO:-add}}
kubectl --context "$CTX" -n infra port-forward svc/anvil "$PORT:8545" >/dev/null 2>&1 & PF=$!
kubectl --context "$CTX" -n infra port-forward svc/anvil-gateway "$GW_PORT:8545" >/dev/null 2>&1 & PF2=$!
trap 'kill $PF $PF2 2>/dev/null' EXIT; sleep 2
cargo run --release --quiet --manifest-path "$HERE/Cargo.toml"
