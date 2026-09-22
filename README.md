# zama-local-practice

Local playground for running the Zama coprocessor on kind with the official Helm chart,
managed by Argo CD. Not meant for testnet or EKS. Later: MPC/KMS under `mpc/`.

Differences from a real deployment: images are built locally (the upstream registry is private),
Postgres runs in the cluster instead of RDS, minio stands in for S3, anvil stands in for the
host chain. Chart, values layout and monitoring are the same.

## Layout

```
cluster/                      one cluster
  kind/cluster.yaml
  bootstrap/                  applied by hand, once: Argo CD install, root app, CoreDNS rewrite,
                              secrets.sh (generates secrets/generated.yaml, gitignored)
  apps/values.yaml            every Argo CD Application (argocd-apps chart values)
  infra/                      Application "infra": postgres, minio, anvil
  platform/<name>/values.yaml third-party charts: monitoring, chaos-mesh
coprocessor/                  everything specific to the coprocessor
  images/                     Dockerfile (workers, host-listener) + build.sh
  values.yaml                 upstream chart values (Application "coprocessor")
  sql-exporter/values.yaml    upstream exporter chart values
  monitoring/                 alert rules + Grafana dashboard
  demo/                       encrypt 3 and 5, add, decrypt (Argo sync-hook Job)
  chaos/  seed/  jobs/  scripts/
mpc/                          later, same shape
```

Rules:

- One root Application (`cluster/bootstrap/root-app.yaml`) is applied by hand. It renders the
  AppProject and every other Application from `cluster/apps/values.yaml`. Adding something to
  the cluster is one entry there.
- Shared components use bare names (`infra`, `monitoring`, `chaos-mesh`); anything that belongs
  to one system carries its prefix (`coprocessor-monitoring`, `coprocessor-demo`).
- A directory is owned by Argo CD if `cluster/apps/values.yaml` points at it. `cluster/bootstrap/`
  and the chaos experiments are always applied by hand.
- Sync waves: 0 infra, 1 monitoring, 2 workers and exporter, 3 rules and chaos, 4 demo.
  Application health checks are on, so a wave waits for the previous one.
- Every child Application carries the resources finalizer and the root prunes: removing or
  renaming an entry deletes the Application and everything it deployed.
- Outputs of one-shot actions go into git: contract addresses land in `coprocessor/values.yaml`
  (the chart renders the `eth-sc-addresses` ConfigMap from them).
- `.fhevm-ref` is the only place the fhevm commit is typed by hand. Images are labelled with it
  and CI checks both chart sources in `cluster/apps/values.yaml` pin it.
- No credentials in git, not even practice ones. `cluster/bootstrap/secrets.sh` generates them into a
  gitignored file that `make bootstrap` applies; manifests and chart values only reference Secret
  names. Scripts get the database URL from the cluster (`cluster/bootstrap/db-url.sh`). A real
  environment would use External Secrets or SOPS instead of a generated file.

## Bring-up

Prereqs: Docker Desktop, kind, kubectl, helm, gh, make, Rust (rustup picks 1.97.1 from the
repo), `protobuf`. The fhevm checkout is expected at `../zama-ai-repos/fhevm` with the
`fhevm-keys` LFS files fetched.

```bash
make up        # kind cluster, images, generated secrets + CoreDNS, Argo CD + deploy key, root app, seed
make job       # 20 ERC20 transfers through the pipeline
make watch     # counters
make demo      # run the end-to-end check as an Argo CD sync
make down
```

`FHEVM_DIR` points at the checkout if it is not next to this repo. Individual steps are the
scripts the Makefile calls. UIs: `make argocd-ui` (:8080), `make grafana` (:13000),
`make prom` (:9090); all anonymous read-only.

## End-to-end check

`coprocessor/demo/` encrypts 3 and 5 (trivial encrypt), asks for the sum, waits for
tfhe-worker, decrypts the result with the test client key and prints `3 + 5 = 8`. It also
waits for sns-worker to upload and record the digests.

```bash
coprocessor/demo/run.sh     # from the laptop against the cluster DB
make demo-image             # build local/coprocessor-demo:dev, load into kind
make demo                   # sync the coprocessor-demo app == run the Job, print its log
```

The client key only exists in the test keyset; on a real network decryption goes through
the KMS, which this setup does not have.

## Notes

- The stress generator writes `computations` but not `dependence_chain`, so tfhe-worker sits on
  "No dcid found". `gen.sh job` runs `scripts/chains.sql` after each job to fill them in.
- The generator's CSV scenario format no longer parses (`batch_size` was added to the struct);
  use `--run-server` and POST JSON.
- zkproof-worker peaks at ~12 GB on startup while it expands the xof keyset, then settles around
  3.5 GB. Limits below that get OOMKilled.
- The S3 SDK addresses buckets as `<bucket>.<host>`; minio in-cluster needs the CoreDNS rewrite
  (with `answer auto`, otherwise glibc rejects the reply).
- anvil keeps its state on a PVC. Without that a pod restart resets the chain to block 0 and the
  host-listener waits forever for a block height it already recorded.
- `BatchSpanProcessor.ExportError` in every log is the missing OTLP collector. Harmless.
