#!/bin/bash
# Pipeline counters from the in-cluster Postgres.
#   ./watch.sh              once
#   ./watch.sh loop         every 2s
#   ./watch.sh sql "..."    ad-hoc query
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
psql() { kubectl --context "$CTX" exec -i -n infra deploy/postgres -- psql -U postgres -d coprocessor "$@"; }
case "${1:-}" in
  loop) while true; do clear; date; psql < "$HERE/watch.sql"; sleep 2; done ;;
  sql)  shift; psql -c "$*" ;;
  *)    psql < "$HERE/watch.sql" ;;
esac
