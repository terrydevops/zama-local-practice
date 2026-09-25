#!/bin/bash
# LAST RESORT: throw the anvil chain away and rebuild everything that depends on it.
# Prefer letting the check-state init container repair the state; run this only when the
# chain is unrecoverable. Requires CONFIRM=yes.
# What it does: wipes the anvil state, restarts anvil, drops the deploy Job's version stamp
# so Argo CD re-runs the host contracts deploy (same deployer, nonce 0, so the addresses in
# eth-sc-addresses stay valid), clears the listener's block cursor for the chain and
# restarts the listener.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
CHAIN_ID=12345
[ "${CONFIRM:-}" = yes ] || { echo "this destroys the local host chain; run with CONFIRM=yes" >&2; exit 1; }
k() { kubectl --context "$CTX" "$@"; }
echo "1/5 stop anvil and wipe its state"
k -n infra scale deploy/anvil --replicas=0
k -n infra wait --for=delete pod -l app=anvil --timeout=120s || true
k -n infra run state-wipe --rm -i --restart=Never --image=busybox --overrides='{"spec":{"containers":[{"name":"w","image":"busybox","command":["sh","-c","rm -f /data/anvil.json /data/anvil.json.*; ls -la /data"],"volumeMounts":[{"name":"s","mountPath":"/data"}]}],"volumes":[{"name":"s","persistentVolumeClaim":{"claimName":"anvil-state"}}]}}'
k -n infra scale deploy/anvil --replicas=1
k -n infra rollout status deploy/anvil --timeout=180s
echo "2/5 re-run the host contracts deploy Job"
k -n coproc patch configmap eth-sc-addresses --type json -p '[{"op":"remove","path":"/data/contracts.version"}]' || true
k -n coproc delete job -l app=fhevm-sc-deploy --ignore-not-found
k -n coproc delete job host-contracts-deploy --ignore-not-found
k -n argocd annotate application coprocessor-host-contracts argocd.argoproj.io/refresh=normal --overwrite >/dev/null
echo "   waiting for Argo CD to recreate and finish the Job"
for _ in $(seq 1 60); do s=$(k -n coproc get job host-contracts-deploy -o jsonpath='{.status.succeeded}' 2>/dev/null || true); [ "$s" = 1 ] && break; sleep 10; done
[ "$s" = 1 ] || { echo "deploy Job did not finish" >&2; exit 1; }
echo "3/5 clear the listener's block cursor for chain $CHAIN_ID"
"$ROOT/coprocessor/scripts/watch.sh" sql "DELETE FROM host_chain_blocks_valid WHERE chain_id=$CHAIN_ID" | tail -1
echo "4/5 restart the listener"
k -n coproc rollout restart deploy -l app.kubernetes.io/name=coprocessor-anvil-listener-host-listener
k -n coproc rollout status deploy -l app.kubernetes.io/name=coprocessor-anvil-listener-host-listener --timeout=180s
echo "5/5 smoke"
"$HERE/smoke.sh"
