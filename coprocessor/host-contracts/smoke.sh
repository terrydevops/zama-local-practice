#!/bin/bash
# One event through the real path: a trivialEncrypt transaction on the anvil chain, picked up
# by the host-listener, written as a computation with its dependence chain, and processed by
# tfhe-worker. A bare trivialEncrypt allows its output to nobody, and the listener inserts
# such outputs as already completed (is_completed = NOT allowed), so no ciphertext is
# materialized and nothing is uploaded: that needs a contract that calls ACL.allow in the same
# transaction. Prints the tx, the listener log line and the rows as they appear.
#   ./smoke.sh [value] [type]   default: 5 as euint8 (type 2)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
export PATH="$HOME/.foundry/bin:$PATH"
VALUE=${1:-5}; TYPE=${2:-2}
PORT=${ANVIL_PORT:-18545}
RPC=http://127.0.0.1:$PORT

cm() { kubectl --context "$CTX" -n coproc get configmap eth-sc-addresses -o "jsonpath={.data.$1}"; }
EXECUTOR=$(cm 'fhevm_executor\.address'); ACL=$(cm 'acl\.address')
[ -n "$EXECUTOR" ] || { echo "eth-sc-addresses has no fhevm_executor.address yet (deploy Job not done?)" >&2; exit 1; }
# sender: account 0 of the phrase in the host-chain-deployer Secret; key derived here, never stored
MNEMONIC=$(kubectl --context "$CTX" -n coproc get secret host-chain-deployer -o 'jsonpath={.data.mnemonic}' | base64 -d)
KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)

kubectl --context "$CTX" -n infra port-forward svc/anvil "$PORT:8545" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT; sleep 2

# keep the seeded host_chains row honest: the ACL address the chain actually has
"$ROOT/coprocessor/scripts/watch.sh" sql "UPDATE host_chains SET acl_contract_address='$ACL' WHERE chain_id=12345" >/dev/null

before=$("$ROOT/coprocessor/scripts/watch.sh" sql "SELECT count(*) FROM computations" -tA)
echo "executor $EXECUTOR on chain $(cast chain-id --rpc-url "$RPC"), block $(cast block-number --rpc-url "$RPC")"
tx=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json "$EXECUTOR" 'trivialEncrypt(uint256,uint8)' "$VALUE" "$TYPE" | jq -r .transactionHash)
echo "tx $tx  trivialEncrypt($VALUE, type $TYPE)"

echo "waiting for the host-listener to write the computation"
for _ in $(seq 1 30); do
  now=$("$ROOT/coprocessor/scripts/watch.sh" sql "SELECT count(*) FROM computations" -tA)
  [ "$now" -gt "$before" ] && break; sleep 2
done
[ "$now" -gt "$before" ] || { echo "no new computations row after 60s" >&2; exit 1; }
"$ROOT/coprocessor/scripts/watch.sh" sql "SELECT encode(output_handle,'hex') AS handle, dependence_chain_id IS NOT NULL AS has_chain, is_completed, is_error FROM computations ORDER BY created_at DESC LIMIT 1"
kubectl --context "$CTX" -n coproc logs -l app.kubernetes.io/name=coprocessor-anvil-listener-host-listener --tail=200 | grep -i "$(echo "$tx" | cut -c3-12)" | head -2 || true

echo "waiting for tfhe-worker to take and release the dependence chain"
for _ in $(seq 1 30); do
  st=$("$ROOT/coprocessor/scripts/watch.sh" sql "SELECT status FROM dependence_chain WHERE dependence_chain_id=decode('${tx#0x}','hex')" -tA)
  [ "$st" = "processed" ] && break; sleep 2
done
"$ROOT/coprocessor/scripts/watch.sh" sql "SELECT encode(dependence_chain_id,'hex') AS dcid, status, block_height FROM dependence_chain WHERE dependence_chain_id=decode('${tx#0x}','hex')"
if [ "$st" = "processed" ]; then
  echo "OK: chain -> host-listener -> computations + dependence_chain -> tfhe-worker (output not allowed, so no ciphertext by design)"
else
  echo "tfhe-worker did not process the dependence chain in 60s" >&2; exit 1
fi
