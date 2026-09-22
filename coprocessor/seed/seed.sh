#!/bin/bash
# Run migrations and import the test FHE keys into the practice Postgres.
# DATABASE_URL defaults to the cluster Postgres via db-url.sh. FHEVM_DIR overrides the checkout location.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
ENGINE=$FHEVM_DIR/coprocessor/fhevm-engine

export DATABASE_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
export SEED_WITH_SNS_PK=${SEED_WITH_SNS_PK:-true}
export SQLX_OFFLINE=true
export SQLX_OFFLINE_DIR=$ENGINE/.sqlx
export PATH="/opt/homebrew/bin:$PATH"

for f in xof-keyset xof-cks pp; do
  if [ "$(wc -c < "$ENGINE/fhevm-keys/$f")" -lt 1000 ]; then
    echo "fhevm-keys/$f is still an LFS pointer, fetch it first" >&2; exit 1
  fi
done

# setup_test_key reads ../fhevm-keys relative to cwd
cd "$ENGINE/test-harness"
cargo run --release --quiet --manifest-path "$HERE/Cargo.toml"
