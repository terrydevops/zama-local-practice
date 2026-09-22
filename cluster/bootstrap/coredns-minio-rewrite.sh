#!/bin/bash
# The AWS S3 SDK addresses buckets as <bucket>.<endpoint-host> (virtual-hosted style)
# and sns-worker has no path-style switch, so `coproc-0.minio.infra.svc.cluster.local`
# must resolve. Real S3 handles this itself; for in-cluster minio we teach CoreDNS to
# rewrite any *.minio.infra.svc.cluster.local to the minio Service.
#   ./coredns-minio-rewrite.sh apply|check
set -euo pipefail
CTX=kind-zama-practice
# `answer auto` rewrites the answer's name back to what was asked, otherwise glibc
# (getaddrinfo) rejects the mismatched reply while busybox nslookup accepts it.
RULE='rewrite stop { name regex (.*)\\.minio\\.infra\\.svc\\.cluster\\.local minio.infra.svc.cluster.local answer auto }'
case "${1:-apply}" in
  apply)
    kubectl --context $CTX -n kube-system get cm coredns -o json \
      | python3 -c "
import json,sys
cm=json.load(sys.stdin); cf=cm['data']['Corefile']
# insert the rewrite right after the opening of the root server block
import re
cf=re.sub(r'\n\s*rewrite[^\n]*minio\\.infra[^\n]*', '', cf)  # drop any earlier variant
cf=cf.replace('.:53 {\n', '.:53 {\n    $RULE\n', 1)
cm['data']['Corefile']=cf; print(json.dumps(cm))" \
      | kubectl --context $CTX -n kube-system apply -f - >/dev/null
    kubectl --context $CTX -n kube-system rollout restart deploy/coredns >/dev/null
    kubectl --context $CTX -n kube-system rollout status deploy/coredns --timeout=60s ;;
  check)
    kubectl --context $CTX run dnscheck --rm -i --restart=Never --image=debian:trixie-slim -n coproc --timeout=60s -- \
      sh -c 'getent hosts coproc-0.minio.infra.svc.cluster.local || echo FAILED' 2>&1 | tail -2 ;;
esac
