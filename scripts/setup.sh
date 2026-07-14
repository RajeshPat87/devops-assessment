#!/usr/bin/env bash
# One-shot local bring-up: cluster + monitoring + app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1/4 Provisioning cluster + monitoring with Terraform"
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve

# Read these from Terraform so they cannot drift from variables.tf.
CLUSTER="$(terraform output -raw cluster_name)"
CONTEXT="kind-$CLUSTER"
export KUBECONFIG="$(terraform output -raw kubeconfig_path)"

# The kubeconfig above is the shared default one, which also holds credentials for
# real clusters. Never let the ambient current-context decide where we deploy:
# pin every client call to this cluster's context explicitly.
kubectl config use-context "$CONTEXT"

echo "==> 2/4 Building application image"
docker build -t hello-web:1.0.0 "$REPO_ROOT/app"

echo "==> 3/4 Loading image into kind"
kind load docker-image hello-web:1.0.0 --name "$CLUSTER"

echo "==> 4/4 Deploying two-tier app with Helm (server-side dry-run first, then apply)"
helm upgrade --install hello-app "$REPO_ROOT/chart" --kube-context "$CONTEXT" \
  --namespace demo-app --dry-run=server
helm upgrade --install hello-app "$REPO_ROOT/chart" --kube-context "$CONTEXT" \
  --namespace demo-app --wait --timeout 180s

echo
echo "Done."
echo "  App:     http://localhost:8080"
echo "  Grafana: http://localhost:3000  (admin / admin123)"
echo
echo "kubectl is now pointed at the '$CONTEXT' context in $KUBECONFIG."
echo "No KUBECONFIG export needed. To switch away:"
echo
echo "  kubectl config use-context <other-context>"
echo
