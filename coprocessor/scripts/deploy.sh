#!/bin/bash
# Render or inspect the coprocessor releases. The releases themselves are owned by Argo CD
# (cluster/apps/values.yaml); change a values file and push instead of helm upgrade.
#   ./deploy.sh render                 render every coprocessor release (workers, listener, gateway, contracts)
#   ./deploy.sh status                 pods in coproc
#   ./deploy.sh logs <name> [lines]    tfhe-worker | sns-worker | zkproof-worker | host-listener
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
CTX=${KUBE_CONTEXT:-kind-zama-practice}
case "${1:-}" in
  render)
    helm template coprocessor "$FHEVM_DIR/charts/coprocessor" -n coproc -f "$ROOT/coprocessor/workers/values.yaml"
    helm template coprocessor-anvil-listener "$FHEVM_DIR/charts/coprocessor" -n coproc -f "$ROOT/coprocessor/listeners/anvil/values.yaml"
    helm template host-contracts "$FHEVM_DIR/charts/contracts" -n coproc -f "$ROOT/coprocessor/host-contracts/values.yaml"
    helm template gateway-contracts "$FHEVM_DIR/charts/contracts" -n coproc -f "$ROOT/coprocessor/gateway-contracts/values.yaml"
    helm template gateway-host-chains "$FHEVM_DIR/charts/contracts" -n coproc -f "$ROOT/coprocessor/gateway-host-chains/values.yaml"
    helm template coprocessor-gateway "$FHEVM_DIR/charts/coprocessor" -n coproc -f "$ROOT/coprocessor/gateway/values.yaml"
    helm template kms-connector "$FHEVM_DIR/charts/kms-connector" -n coproc -f "$ROOT/coprocessor/kms-connector/values.yaml"
    helm template gateway-kms-context "$FHEVM_DIR/charts/contracts" -n coproc -f "$ROOT/coprocessor/gateway-kms-context/values.yaml"
    helm template host-kms-keygen "$FHEVM_DIR/charts/contracts" -n coproc -f "$ROOT/coprocessor/host-kms-keygen/values.yaml" ;;
  status) kubectl --context "$CTX" get pods -n coproc -o wide ;;
  logs)
    case "${2:-}" in
      host-listener) sel="app.kubernetes.io/name=coprocessor-anvil-listener-host-listener" ;;
      gw-listener|tx-sender) sel="app=coprocessor-$2" ;;
      kms-core) sel="app=kms-core" ;;
      kms-gw-listener|kms-worker|kms-tx-sender) sel="app.kubernetes.io/name=kms-connector-${2#kms-}" ;;
      tfhe-worker|sns-worker|zkproof-worker) sel="app=coprocessor-$2" ;;
      *) echo "usage: $0 logs tfhe-worker|sns-worker|zkproof-worker|host-listener|gw-listener|tx-sender|kms-core|kms-gw-listener|kms-worker|kms-tx-sender [lines]" >&2; exit 1 ;;
    esac
    kubectl --context "$CTX" logs -n coproc -l "$sel" --tail="${3:-50}" -f ;;
  *) echo "usage: $0 render|status|logs <name> [lines]" ;;
esac
