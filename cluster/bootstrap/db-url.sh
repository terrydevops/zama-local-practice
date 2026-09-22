#!/bin/bash
# Print the DATABASE_URL for reaching the cluster Postgres from the laptop (kind NodePort
# 5432), with the password read from the coprocessor-db Secret. Scripts default to this.
set -euo pipefail
CTX=${KUBE_CONTEXT:-kind-zama-practice}
get() { kubectl --context "$CTX" -n coproc get secret coprocessor-db -o "jsonpath={.data.$1}" | base64 -d; }
echo "postgresql://$(get username):$(get password)@127.0.0.1:${PG_PORT:-5432}/coprocessor"
