# zama-local-practice

Local playground for running the Zama coprocessor on kind with the official Helm chart,
managed by Argo CD. Not meant for testnet or EKS. Later: MPC/KMS under `mpc/`.

Differences from a real deployment: images are built locally (the upstream registry is private),
Postgres runs in the cluster instead of RDS, minio stands in for S3 (both on PVCs), one anvil
stands in for the host chain and another for Zama's Gateway chain. Chart, values layout and monitoring are the same.

## Layout

```
cluster/                      one cluster
  kind/cluster.yaml
  bootstrap/                  applied by hand, once: Argo CD install, root app, CoreDNS rewrite,
                              secrets.sh (generates secrets/generated.yaml, gitignored)
  apps/values.yaml            every Argo CD Application (argocd-apps chart values)
  infra/                      Application "infra": postgres, minio, anvil (host chain), anvil-gateway
  platform/<name>/values.yaml third-party charts: monitoring, chaos-mesh
coprocessor/                  everything specific to the coprocessor
  images/                     Dockerfiles (workers, host-listener, host-contracts) + build.sh
  workers/values.yaml         upstream chart, workers release (Application "coprocessor-workers")
  listeners/<chain>/values.yaml   upstream chart, one host-listener release per chain
  host-contracts/             contracts chart values (host deploy Job) + smoke.sh + chain-reset.sh
  gateway-contracts/values.yaml   contracts chart values (gateway deploy Job)
  gateway-host-chains/values.yaml contracts chart values (register the host chain on the Gateway)
  gateway/values.yaml         upstream chart, gateway release: gw-listener + tx-sender
  host-kms-keygen/values.yaml contracts chart Job: key + CRS generation requests on the host chain
  kms-core/                   centralized KMS core, plain manifests
  kms-connector/values.yaml   upstream chart: the KMS side's gw-listener, kms-worker, tx-sender
  sql-exporter/values.yaml    upstream exporter chart values
  chain-exporter/values.yaml  public sql_exporter chart with our own chain-progress queries
  monitoring/                 alert rules + Grafana dashboard
  demo/                       contracts + Rust runner: on-chain checks through the coprocessor (sync-hook Jobs)
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
- The coprocessor chart is installed as several releases, the way coprocessor-operator does it:
  workers, one listener per host chain, later the gateway side. Each is its own Application.
- Sync waves: 0 infra (both chains), 1 monitoring and kms-core, 2 gateway contracts Job, workers
  and exporters, 3 host contracts Job, rules and chaos, 4 host chain registration, listeners,
  gateway side and kms-connector, 5 key generation and demo. Like the upstream e2e stack: the
  KMS comes first so the contracts register its real signer, then gateway, host, registration. Application health checks are on, so a wave waits for
  the previous one.
- Every child Application carries the resources finalizer and the root prunes: removing or
  renaming an entry deletes the Application and everything it deployed.
- One-shot actions run as Jobs that record their output in the cluster: the host contracts
  deploy Job writes every address into the ConfigMap `eth-sc-addresses`, and the listener reads
  it by key. The Job stamps the version it deployed and is a no-op afterwards.
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
make demo      # on-chain checks: 3 + 5, and a confidential token transfer
make smoke     # one trivialEncrypt on the anvil chain, followed into the DB and tfhe-worker
make down
```

`FHEVM_DIR` points at the checkout if it is not next to this repo. Individual steps are the
scripts the Makefile calls. UIs: `make argocd-ui` (:8080), `make grafana` (:13000),
`make prom` (:9090); all anonymous read-only.

## End-to-end checks

`coprocessor/demo/` runs contracts on the anvil chain and follows their results through the
whole system: host-listener turns the events into computations, tfhe-worker computes,
sns-worker uploads the ciphertext to the bucket, transaction-sender commits its digest on the
gateway; the runner then sends a public decryption request to the gateway's `Decryption`
contract, kms-connector picks it up, checks the host ACL, fetches the ciphertext, and the KMS
answers on the gateway chain. The runner reads the answer from the `PublicDecryptionResponse`
event. Nothing outside the KMS holds a decryption key.
Two scenarios, each an Argo CD sync-hook Job of the `coprocessor-demo` application:

- `add`: `contracts/src/Add.sol` encrypts 3 and 5, adds them, allows the caller and makes
  the sum publicly decryptable, in one transaction. Prints `3 + 5 = 8`.
- `transfer`: `contracts/src/PracticeToken.sol` inherits the upstream `EncryptedERC20`
  example. Mint 1000, transfer 250, then try to transfer 900: the contract moves an
  encrypted 0 instead and the chain shows the same Transfer event either way. Balances are
  private until the practice-only `reveal` marks them publicly decryptable (the runner prints
  the ACL answer before and after); the KMS then returns 750 and 250.

```bash
coprocessor/demo/run.sh [add|transfer]   # from the laptop: forge build, port-forward both anvils, cargo run
make demo-image                          # build local/coprocessor-demo:dev (forge stage + Rust), load into kind
make demo                                # sync the coprocessor-demo app == run both Jobs, print their logs
```

Local-only shortcuts, all in the runner: the sender gives itself gas on the gateway anvil, and
the fee is paid with the mocked ZAMA token that `deployAllGatewayContractsForTests` deploys,
minted on the spot. Encrypted inputs with proofs (`transfer` with an `externalEuint64`) need
the relayer, which is not here; `transferPlain` encrypts the amount inside the contract instead.

## Notes

- The stress generator writes `computations` but not `dependence_chain`, so tfhe-worker sits on
  "No dcid found". `gen.sh job` runs `scripts/chains.sql` after each job to fill them in.
- The generator's CSV scenario format no longer parses (`batch_size` was added to the struct);
  use `--run-server` and POST JSON.
- zkproof-worker peaks at ~12 GB on startup while it expands the xof keyset, then settles around
  3.5 GB. Limits below that get OOMKilled.
- The S3 SDK addresses buckets as `<bucket>.<host>`; minio in-cluster needs the CoreDNS rewrite
  (with `answer auto`, otherwise glibc rejects the reply).
- Only outputs that a contract allows (ACL.allow in the same transaction) get computed and
  uploaded; the listener inserts everything else as already completed. `make smoke` therefore
  proves chain -> listener -> worker, not an upload. An on-chain add with allow is the next step.
- The host chain is anvil with the upstream test-suite flags and mnemonic; the contracts deploy
  Job and `make smoke` use accounts derived from it. anvil keeps its state on a PVC. Without
  that a pod restart resets the chain to block 0 and the host-listener waits forever for a
  block height it already recorded.
- `BatchSpanProcessor.ExportError` in every log is the missing OTLP collector. Harmless.
