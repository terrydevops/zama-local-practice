#!/bin/bash
# Render or inspect the workers. The release itself is owned by Argo CD (coprocessor app in
# cluster/apps/values.yaml); change coprocessor/values.yaml and push instead of helm upgrade.
#   ./deploy.sh render | status | logs <tfhe-worker|sns-worker|zkproof-worker> [lines]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
CHART=$FHEVM_DIR/charts/coprocessor
VALUES=$ROOT/coprocessor/values.yaml
CTX=${KUBE_CONTEXT:-kind-zama-practice}
case "${1:-}" in
  render) helm template coprocessor "$CHART" -n coproc -f "$VALUES" ;;
  status) kubectl --context "$CTX" get pods -n coproc -o wide ;;
  logs)   kubectl --context "$CTX" logs -n coproc -l "app=coprocessor-${2:?tfhe-worker|sns-worker|zkproof-worker}" --tail="${3:-50}" -f ;;
  *) echo "usage: $0 render|status|logs <name> [lines]" ;;
esac
