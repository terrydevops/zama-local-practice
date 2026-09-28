#!/bin/bash
# Where the Docker disk went. `docker system df` files the kind nodes under "volumes" and
# hides what is inside them; the 43 GB of anvil state files of 2026-09-28 sat in container
# writable layers, which no PVC size or volume listing shows. This prints the layers too.
#   ./disk.sh            Docker VM disk, then per kind node: images, writable layers, PVC data
set -euo pipefail
CLUSTER=${KIND_CLUSTER:-zama-practice}

echo "== Docker VM disk"
docker run --rm -v /var/lib/docker:/d:ro alpine:3.20 df -h /d | tail -1
echo
echo "== docker system df"
docker system df
for node in $(kind get nodes --name "$CLUSTER" 2>/dev/null); do
  echo
  echo "== $node"
  docker exec "$node" sh -c '
    c=/var/lib/containerd
    printf "images (content store)      %s\n" "$(du -xsh $c/io.containerd.content.v1.content 2>/dev/null | cut -f1)"
    printf "layers (overlayfs snapshots) %s\n" "$(du -xsh $c/io.containerd.snapshotter.v1.overlayfs 2>/dev/null | cut -f1)"
    printf "PVC data                     %s\n" "$(du -xsh /var/local-path-provisioner 2>/dev/null | cut -f1)"
    printf "container logs               %s\n" "$(du -xsh /var/log/pods 2>/dev/null | cut -f1)"
    echo "-- biggest writable layers (MB, container, pod)"
    crictl stats -o json 2>/dev/null | python3 -c "
import sys, json
rows = []
for s in json.load(sys.stdin).get(\"stats\", []):
    a = s.get(\"attributes\", {})
    used = int(s.get(\"writableLayer\", {}).get(\"usedBytes\", {}).get(\"value\", 0))
    rows.append((used / 1e6, a.get(\"metadata\", {}).get(\"name\", \"?\"), a.get(\"labels\", {}).get(\"io.kubernetes.pod.name\", \"?\")))
for r in sorted(rows, reverse=True)[:5]:
    print(\"%8.0f  %-28s %s\" % r)
"
    echo "-- biggest PVCs"
    du -xsm /var/local-path-provisioner/* 2>/dev/null | sort -rn | head -4 | sed -E "s#/var/local-path-provisioner/pvc-[0-9a-f-]+_##"
  '
done
