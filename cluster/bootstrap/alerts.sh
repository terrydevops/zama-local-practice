#!/bin/bash
# The alerts firing in the practice cluster, once or as a watch that pops a desktop notification
# for each new one (macOS). A rule that fires with nobody listening is not an alert: the node
# disk rules fired for two days before anyone looked (see cluster/infra/anvil.yaml).
#   ./alerts.sh           print active alerts once
#   ./alerts.sh watch     poll every 60s, print and notify on new alerts
set -euo pipefail
CTX=${KUBE_CONTEXT:-kind-zama-practice}
PORT=${ALERTMANAGER_PORT:-19093}
kubectl --context "$CTX" -n monitoring port-forward svc/monitoring-alertmanager "$PORT:9093" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT; sleep 2

fetch() {
  curl -sf "http://127.0.0.1:$PORT/api/v2/alerts?active=true&silenced=false" | python3 -c '
import sys, json
for a in sorted(json.load(sys.stdin), key=lambda a: (a["labels"].get("severity", ""), a["labels"]["alertname"])):
    l = a["labels"]
    if l["alertname"] == "Watchdog":
        continue
    text = a["annotations"].get("summary") or a["annotations"].get("description", "")
    print("%-9s %-38s %s" % (l.get("severity", "-"), l["alertname"], text[:100]))'
}

notify() {
  command -v osascript >/dev/null || return 0
  osascript -e "display notification \"$(printf '%s' "$1" | head -3 | cut -c1-110 | tr '\n' ' ' | tr -d '"')\" with title \"zama-practice alerts\"" >/dev/null 2>&1 || true
}

case "${1:-}" in
  watch)
    seen=""
    while true; do
      now=$(fetch || true)
      new=$(comm -13 <(printf '%s\n' "$seen" | sort) <(printf '%s\n' "$now" | sort) | sed '/^$/d')
      if [ -n "$new" ]; then
        printf '%s  new:\n%s\n' "$(date +%H:%M)" "$new"
        notify "$new"
      fi
      seen=$now
      sleep 60
    done ;;
  *) fetch ;;
esac
