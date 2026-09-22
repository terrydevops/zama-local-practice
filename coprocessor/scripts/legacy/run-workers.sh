#!/bin/bash
# Legacy: run the three workers as plain processes against a local Postgres + minio
# (pre-kind setup). Kept for reference; the kind flow is the maintained one.
# Usage: ./run-workers.sh start|stop|status|logs <tfhe|sns|zk>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
ENGINE=$FHEVM_DIR/coprocessor/fhevm-engine
BIN=$ENGINE/target/release
LOGDIR=$(dirname "$0")/logs
mkdir -p "$LOGDIR"

export DATABASE_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
# minio from the earlier fhevm-cli run (buckets coproc-0..4)
export AWS_ACCESS_KEY_ID=fhevm-access-key
AWS_SECRET_ACCESS_KEY=$(grep '^SECRET_KEY=' "$FHEVM_DIR/.fhevm/runtime/env/minio.env" | cut -d= -f2-)
export AWS_SECRET_ACCESS_KEY
export AWS_ENDPOINT_URL=http://127.0.0.1:9000
export AWS_REGION=eu-west-1
export FORCE_LEGACY_SERVER_KEY=false
# throwaway dev key for sns-worker attestation signing (anvil account #0)
SNS_SIGNER_KEY=0x<anvil-account-0-key>

start_one() {
  local name=$1; shift
  if pgrep -f "$BIN/$name" >/dev/null; then echo "$name already running"; return; fi
  nohup "$BIN/$name" "$@" > "$LOGDIR/$name.log" 2>&1 &
  echo "$name pid $!"
}

case "${1:-}" in
  start)
    start_one tfhe_worker --run-bg-worker --database-url "$DATABASE_URL" \
      --coprocessor-fhe-threads 8 --work-items-batch-size 20 \
      --health-check-port 8081 --metrics-addr 127.0.0.1:9101 --log-level info
    start_one sns_worker --database-url "$DATABASE_URL" \
      --pg-listen-channels event_pbs_computations event_ciphertext_computed \
      --pg-notify-channel event_ciphertext128_computed \
      --bucket-name coproc-0 --enable-compression \
      --signer-type private-key --private-key "$SNS_SIGNER_KEY" \
      --health-check-port 8082 --metrics-addr 127.0.0.1:9102 --log-level info
    start_one zkproof_worker --database-url "$DATABASE_URL" \
      --pg-listen-channel event_zkpok_new_work --pg-notify-channel event_zkpok_computed \
      --health-check-port 8083 --metrics-addr 127.0.0.1:9103 --log-level info
    ;;
  stop)
    for n in tfhe_worker sns_worker zkproof_worker; do if pkill -f "$BIN/$n"; then echo "stopped $n"; fi; done
    ;;
  status)
    for n in tfhe_worker sns_worker zkproof_worker; do
      if pgrep -f "$BIN/$n" >/dev/null; then echo "$n: running"; else echo "$n: stopped"; fi
    done
    ;;
  logs)
    case "${2:-}" in tfhe) tail -f "$LOGDIR/tfhe_worker.log";; sns) tail -f "$LOGDIR/sns_worker.log";; zk) tail -f "$LOGDIR/zkproof_worker.log";; *) echo "logs tfhe|sns|zk";; esac
    ;;
  *) echo "usage: $0 start|stop|status|logs <tfhe|sns|zk>";;
esac
