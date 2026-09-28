# One entry point for the practice cluster. Each target is idempotent.
#   make up        cluster, images, hand-applied bits, Argo CD, root app, seed
#   make down      delete the kind cluster
#   make job       inject 20 ERC20 transfers and create dependence chains
#   make watch     pipeline counters
#   make demo      3 + 5 and a confidential transfer, decrypted by the KMS: Argo CD sync of coprocessor-demo
#   make smoke     one trivialEncrypt on the anvil chain, watched through listener and workers
#   make lint      the CI gates that run without a cluster (yamllint if installed)
SHELL := /bin/bash
CLUSTER ?= zama-practice
CTX     := kind-$(CLUSTER)
FHEVM_DIR ?= $(CURDIR)/../zama-ai-repos/fhevm
export FHEVM_DIR KUBE_CONTEXT=$(CTX) KIND_CLUSTER=$(CLUSTER)

.PHONY: up cluster images bootstrap argocd root wait-infra seed job watch render check-ref lint demo-image demo smoke chain-compact chain-reset argocd-ui alerts alert-watch disk grafana prom down

up: cluster images bootstrap argocd root wait-infra seed

cluster:
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config cluster/kind/cluster.yaml
	kubectl --context $(CTX) get nodes

images:
	coprocessor/images/build.sh load

# Everything Argo CD does not own: generated credentials and the CoreDNS rewrite.
bootstrap:
	cluster/bootstrap/secrets.sh
	kubectl --context $(CTX) apply -f cluster/bootstrap/secrets/generated.yaml
	cluster/bootstrap/coredns-minio-rewrite.sh apply

argocd:
	cluster/bootstrap/install.sh argocd
	cluster/bootstrap/install.sh repo-key

root:
	cluster/bootstrap/install.sh root

wait-infra:
	@until kubectl --context $(CTX) -n infra get deploy postgres >/dev/null 2>&1; do sleep 5; done
	kubectl --context $(CTX) -n infra rollout status deploy/postgres --timeout=300s
	kubectl --context $(CTX) -n infra rollout status deploy/minio --timeout=300s

seed:
	coprocessor/seed/seed.sh

job:
	coprocessor/scripts/gen.sh server
	coprocessor/scripts/gen.sh job erc20-20.json

watch:
	coprocessor/scripts/watch.sh

render:
	coprocessor/scripts/deploy.sh render > /dev/null && echo "charts render"

# Every upstream chart source in cluster/apps/values.yaml must pin the commit in .fhevm-ref.
check-ref:
	@ref=$$(cat .fhevm-ref); n=$$(grep -c "targetRevision: $$ref" cluster/apps/values.yaml); \
	if [ "$$n" = 9 ]; then echo "cluster/apps/values.yaml pins fhevm $${ref:0:8} ($$n sources)"; \
	else echo "cluster/apps/values.yaml must pin .fhevm-ref ($$ref) on all nine upstream chart sources, found $$n" >&2; exit 1; fi

lint: check-ref
	git ls-files -z '*.sh' | xargs -0 shellcheck -S warning
	git ls-files -z '*Dockerfile*' | xargs -0 hadolint
	@command -v yamllint >/dev/null && yamllint --strict . || echo "yamllint not installed, skipped"
	.github/scripts/list-images.sh --check
	cd coprocessor/demo && cargo fmt --check
	$(MAKE) render

demo-image:
	coprocessor/demo/build.sh load

demo:
	kubectl --context $(CTX) -n argocd patch application coprocessor-demo --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'
	@for j in add transfer; do \
	  until kubectl --context $(CTX) -n coproc get job/coprocessor-demo-$$j >/dev/null 2>&1; do sleep 3; done; \
	  kubectl --context $(CTX) -n coproc wait --for=condition=complete job/coprocessor-demo-$$j --timeout=600s >/dev/null || true; \
	  echo "== $$j"; kubectl --context $(CTX) -n coproc logs job/coprocessor-demo-$$j; done

smoke:
	coprocessor/host-contracts/smoke.sh

# Compact the anvil state now (the init container does it on every start); the weekly CronJob does the same.
chain-compact:
	kubectl --context $(CTX) -n infra rollout restart deployment/anvil
	kubectl --context $(CTX) -n infra rollout status deployment/anvil --timeout=300s
	kubectl --context $(CTX) -n infra logs deployment/anvil -c check-state

# Last resort, destroys the local host chain: CONFIRM=yes make chain-reset
chain-reset:
	CONFIRM=$(CONFIRM) coprocessor/host-contracts/chain-reset.sh

argocd-ui:
	cluster/bootstrap/install.sh ui

# firing alerts, once; alert-watch keeps polling and notifies on the desktop
alerts:
	cluster/bootstrap/alerts.sh

alert-watch:
	cluster/bootstrap/alerts.sh watch

# where the Docker disk went, including the container writable layers docker system df hides
disk:
	cluster/bootstrap/disk.sh

grafana:
	@echo "http://localhost:13000  (anonymous read-only; admin password: secret grafana-admin in monitoring)"
	kubectl --context $(CTX) -n monitoring port-forward svc/monitoring-grafana 13000:80

prom:
	kubectl --context $(CTX) -n monitoring port-forward svc/monitoring-prometheus 9090:9090

down:
	-coprocessor/scripts/gen.sh stop
	kind delete cluster --name $(CLUSTER)
