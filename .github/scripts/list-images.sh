#!/usr/bin/env bash
# List every container image this repo references: image: lines in the plain manifests, the
# chart values that override an image, and the base images of the Dockerfiles (ARG defaults
# resolved). Images built here (local/*) are not in any registry and are left out.
#   --json    matrix for the image scan (registries that refuse anonymous pulls left out)
#   --check   fail on an unpinned or floating tag
set -euo pipefail
cd "$(dirname "$0")/../.."

manifests() {
  git ls-files -z 'cluster/infra/*.yaml' 'coprocessor/kms-core/*.yaml' 'coprocessor/demo/k8s/*.yaml' \
    | xargs -0 grep -hE '^[[:space:]]*(-[[:space:]]*)?image:' \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]*#.*$//'
}

# chart values written as repository: + tag: on consecutive lines
chart_values() {
  awk '/^[[:space:]]*repository:/ {r=$2} /^[[:space:]]*tag:/ {gsub(/"/,"",$2); if (r) print r ":" $2; r=""}' \
    coprocessor/chain-exporter/values.yaml
}

# FROM lines, with ${VAR} resolved from the ARG defaults of the same file. With "runtime" only
# the bases of stages that end up in an image are listed; a stage another stage copies from
# (COPY --from=builder) is build-only and never runs in the cluster.
dockerfiles() {
  local f mode=${1:-all}
  while IFS= read -r -d '' f; do
    awk -v mode="$mode" '
      /^ARG [A-Za-z_]+=/ { split($2, kv, "="); arg[kv[1]] = kv[2] }
      /^FROM / {
        img = $2
        while (match(img, /\$\{[A-Za-z_]+\}/)) {
          name = substr(img, RSTART + 2, RLENGTH - 3)
          img = substr(img, 1, RSTART - 1) arg[name] substr(img, RSTART + RLENGTH)
        }
        if (img ~ /[:@]/) base[($3 == "AS") ? $4 : NR] = img
      }
      /^COPY --from=/ { split($2, kv, "="); buildonly[kv[2]] = 1 }
      END { for (a in base) if (mode != "runtime" || !(a in buildonly)) print base[a] }
    ' "$f"
  done < <(git ls-files -z '*Dockerfile*')
}

images() { { manifests; chart_values; dockerfiles "${1:-all}"; } | grep -v '^local/' | grep -v '^$' | sort -u; }

check() {
  local bad=0 img tag
  while read -r img; do
    [[ "$img" == *'${'* ]] && { echo "UNRESOLVED variable: $img"; bad=1; continue; }
    [[ "$img" =~ @sha256:[0-9a-f]{64}$ ]] && continue
    tag=${img##*:}
    if [[ "$img" != *:* || "$tag" == */* ]]; then echo "UNPINNED (no tag): $img"; bad=1; continue; fi
    case "$tag" in
      latest|stable|main|master|edge|nightly|dev) echo "FLOATING tag: $img"; bad=1 ;;
    esac
    [[ "$tag" =~ ^v?[0-9]+(-[a-z]+)?$ ]] && { echo "FLOATING (major-only tag): $img"; bad=1; }
  done
  return "$bad"
}

case "${1:-}" in
  # quay.io refuses anonymous pulls of the minio images, so the scanner cannot fetch them
  --json)  images runtime | grep -v '^quay.io/minio/' | python3 -c 'import sys,json; print(json.dumps([l for l in sys.stdin.read().split("\n") if l]))' ;;
  --check) images | check && echo "all $(images | wc -l | tr -d ' ') image references pinned" ;;
  *)       images ;;
esac
