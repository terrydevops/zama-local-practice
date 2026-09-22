#!/bin/bash
# Drive the upstream stress-test-generator in server mode. It stands in for the host chain
# and host-listener and writes synthetic FHE ops straight into Postgres.
#   ./gen.sh server            start the API on 127.0.0.1:3000
#   ./gen.sh job <file.json>   submit a job (jobs/ or the generator's data/json/), wait for it,
#                              then create the dependence_chain rows the generator leaves out
#   ./gen.sh status | stop
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
GEN=$FHEVM_DIR/coprocessor/fhevm-engine/stress-test-generator
BIN=$FHEVM_DIR/coprocessor/fhevm-engine/target/release/stress_generator
LOGDIR=$HERE/logs; mkdir -p "$LOGDIR"
API=http://127.0.0.1:3000
export EVGEN_DB_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
export CHAIN_ID=12345
# must match the host_chains row seeded by test-harness
export ACL_CONTRACT_ADDRESS=0x339EcE85B9E11a3A3AA557582784a15d7F82AAf2

case "${1:-}" in
  server)
    if pgrep -f "$BIN" >/dev/null; then echo "generator already running"; exit 0; fi
    cd "$GEN"   # relative data paths
    nohup "$BIN" --run-server --listen-address 127.0.0.1:3000 --log-level info > "$LOGDIR/generator.log" 2>&1 &
    echo "generator pid $! (log: $LOGDIR/generator.log)" ;;
  job)
    f=${2:?json file}
    [ -f "$f" ] || f="$HERE/../jobs/$2"
    [ -f "$f" ] || f="$GEN/data/json/$2"
    id=$(curl -sf -X POST -H 'Content-Type: application/json' --data-binary @"$f" "$API/job" | sed -E 's/.*"id":([0-9]+).*/\1/')
    echo "job $id submitted"
    until [ "$(curl -s "$API/status/running")" = "null" ] && [[ "$(curl -s "$API/status/queued")" =~ ^(null|\[\])$ ]]; do sleep 2; done
    echo "job $id done, creating dependence chains"
    "$HERE/watch.sh" sql "$(cat "$HERE/chains.sql")" | tail -2 ;;
  status)
    echo "running: $(curl -s "$API/status/running")"; echo "queued: $(curl -s "$API/status/queued")" ;;
  stop) if pkill -f "$BIN"; then echo stopped; fi ;;
  *) echo "usage: $0 server|job <file.json>|status|stop" ;;
esac
