#!/bin/bash
# Pipeline counters from the in-cluster Postgres.
#   ./watch.sh              once
#   ./watch.sh loop         every 2s
#   ./watch.sh sql "..." [psql flags]    ad-hoc query, e.g. -tA for a bare value
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
psql() { kubectl --context "$CTX" exec -i -n infra deploy/postgres -- psql -U postgres -d coprocessor "$@"; }
case "${1:-}" in
  loop) while true; do clear; date; psql < "$HERE/watch.sql"; sleep 2; done ;;
  sql)  shift; q=$1; shift; psql "$@" -c "$q" ;;
  *)    psql < "$HERE/watch.sql" ;;
esac
