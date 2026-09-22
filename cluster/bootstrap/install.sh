#!/bin/bash
# Install Argo CD into the practice cluster and hand it the root application.
#   ./install.sh argocd      helm install Argo CD (values in argocd-values.yaml)
#   ./install.sh repo-key    create a read-only SSH deploy key, add it to the GitHub repo (gh),
#                            and register it in Argo CD as the repo credential
#   ./install.sh root        apply root-app.yaml; Argo CD creates everything else from cluster/apps/values.yaml
#   ./install.sh password    print the initial admin password
#   ./install.sh ui          port-forward the UI to localhost:8080
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CTX=${KUBE_CONTEXT:-kind-zama-practice}
REPO=terrydevops/zama-local-practice
KEY=$HERE/.deploy-key          # gitignored
case "${1:-}" in
  argocd)
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update argo >/dev/null
    helm --kube-context "$CTX" upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
      -f "$HERE/argocd-values.yaml" --wait --timeout 5m
    kubectl --context "$CTX" get pods -n argocd ;;
  repo-key)
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -C "argocd@zama-practice (read-only)" -f "$KEY" >/dev/null
    gh repo deploy-key add "$KEY.pub" -R "$REPO" --title "argocd zama-practice (read-only)" 2>/dev/null || echo "deploy key already on GitHub"
    kubectl --context "$CTX" -n argocd create secret generic repo-zama-local-practice \
      --from-literal=type=git --from-literal=url="git@github.com:$REPO.git" \
      --from-file=sshPrivateKey="$KEY" --dry-run=client -o yaml \
      | kubectl --context "$CTX" label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
      | kubectl --context "$CTX" apply -f - ;;
  root)    kubectl --context "$CTX" apply -f "$HERE/root-app.yaml"
           kubectl --context "$CTX" -n argocd get applications ;;
  password) kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo ;;
  ui)      kubectl --context "$CTX" -n argocd port-forward svc/argocd-server 8080:80 ;;
  *) echo "usage: $0 argocd|repo-key|root|password|ui";;
esac
