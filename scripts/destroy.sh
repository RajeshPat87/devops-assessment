#!/usr/bin/env bash
# Tears down everything Terraform created, including the kind cluster.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/terraform"
terraform destroy -auto-approve
