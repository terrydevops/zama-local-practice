#!/usr/bin/env bash
# kubeconform, pinned, from its container image: manifests on stdin or as file arguments.
# The CRD schemas (Argo CD, Prometheus Operator, Chaos Mesh) come from the datree catalog.
set -euo pipefail
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
IMAGE=ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e
exec docker run --rm -i -v "$PWD:/repo:ro" -w /repo "$IMAGE" \
  -strict -summary -schema-location default -schema-location "$CRDS" "$@"
