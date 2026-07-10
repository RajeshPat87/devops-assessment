#!/usr/bin/env bash
# One-shot local bring-up: cluster + monitoring + app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER=devops-assessment

echo "==> 1/4 Provisioning cluster + monitoring with Terraform"
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve

export KUBECONFIG="$HOME/.kube/devops-assessment-config"

echo "==> 2/4 Building application image"
docker build -t hello-web:1.0.0 "$REPO_ROOT/app"

echo "==> 3/4 Loading image into kind"
kind load docker-image hello-web:1.0.0 --name "$CLUSTER"

echo "==> 4/4 Deploying two-tier app with Helm (server-side dry-run first, then apply)"
helm upgrade --install hello-app "$REPO_ROOT/chart" --namespace demo-app --dry-run=server
helm upgrade --install hello-app "$REPO_ROOT/chart" --namespace demo-app --wait --timeout 180s

echo
echo "Done."
echo "  App:     http://localhost:8080"
echo "  Grafana: http://localhost:3000  (admin / admin123)"
