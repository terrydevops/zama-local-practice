#!/bin/bash
# Run the encrypt-add-decrypt check against the practice Postgres (DATABASE_URL defaults to
# the cluster DB via db-url.sh). X and Y override the two numbers.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FHEVM_DIR=${FHEVM_DIR:-$ROOT/../zama-ai-repos/fhevm}
export DATABASE_URL=${DATABASE_URL:-$("$ROOT/cluster/bootstrap/db-url.sh")}
export SQLX_OFFLINE=true
export SQLX_OFFLINE_DIR=$FHEVM_DIR/coprocessor/fhevm-engine/.sqlx
export PATH="/opt/homebrew/bin:$PATH"
cargo run --release --quiet --manifest-path "$HERE/Cargo.toml"
