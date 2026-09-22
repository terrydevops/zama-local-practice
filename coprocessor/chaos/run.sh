#!/bin/bash
# Run one chaos experiment end to end and print a timeline of the signals that matter.
#   ./run.sh c1        sns-worker down (PodChaos)
#   ./run.sh c2        sns-worker cut off from minio (NetworkChaos)
#   ./run.sh clean     delete any experiment left over
# Requires: Chaos Mesh installed, generator API running (gen.sh server), prometheus reachable
# via port-forward on 127.0.0.1:19090 (started here if missing).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
PROM=http://127.0.0.1:19090
k() { kubectl --context "$CTX" "$@"; }
q() { curl -s --data-urlencode "query=$1" "$PROM/api/v1/query" | python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "-")'; }
alerts() { curl -s "$PROM/api/v1/alerts" | python3 -c 'import sys,json; a=[x["labels"]["alertname"]+":"+x["state"] for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"]["alertname"].startswith("Coprocessor")]; print(",".join(a) or "-")'; }

case "${1:-}" in
  c1) FILE=$HERE/c1-sns-worker-down.yaml; NAME=c1-sns-worker-down; KIND=podchaos; DUR=300 ;;
  c2) FILE=$HERE/c2-s3-partition.yaml;    NAME=c2-s3-partition;    KIND=networkchaos; DUR=360 ;;
  clean) k -n coproc delete podchaos,networkchaos --all; exit 0 ;;
  *) echo "usage: $0 c1|c2|clean"; exit 1 ;;
esac

if ! curl -sf "$PROM/-/ready" >/dev/null; then
  k -n monitoring port-forward svc/monitoring-prometheus 19090:9090 >/dev/null 2>&1 &
  sleep 3
fi

echo "== $(date +%T) apply $NAME"
k apply -f "$FILE" >/dev/null
sleep 5
echo "== $(date +%T) inject a job"
"$HERE/../scripts/gen.sh" job erc20-20.json | tail -1

printf '%-9s %-8s %-8s %-8s %-10s %s\n' time comp_todo pbs_todo upl_inc  s3_fail alerts
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt $(( DUR + 240 )) ]; do
  printf '%-9s %-8s %-8s %-8s %-10s %s\n' "$(date +%T)" \
    "$(q 'computations_completion{status="uncompleted"}')" \
    "$(q 'pbs_completion{status="uncompleted"}')" \
    "$(q 'coprocessor_sns_worker_uncomplete_aws_uploads_gauge')" \
    "$(q 'increase(coprocessor_sns_worker_aws_upload_failure_counter[2m])')" \
    "$(alerts)"
  sleep 30
done
echo "== $(date +%T) experiment status:"
k -n coproc get "$KIND" "$NAME" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
k -n coproc delete "$KIND" "$NAME" >/dev/null && echo "== cleaned up"
