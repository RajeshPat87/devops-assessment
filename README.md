# Lead DevOps Engineer - Technical Assessment

Single-node Kubernetes cluster provisioned with Terraform (kind), running a
two-tier application (Flask + PostgreSQL) with a Prometheus/Grafana monitoring
stack, deployed through a GitHub Actions pipeline.

Architecture decisions, scalability path, SPOF post-mortem and trade-offs are
in [DESIGN.md](DESIGN.md).

```
├── terraform/            # kind cluster + namespaces + kube-prometheus-stack
├── app/                  # Flask app + multi-stage Dockerfile
├── k8s/                  # ConfigMap, Secret, Postgres StatefulSet+PVC, Web Deployment
├── .github/workflows/    # ci-cd.yaml (validate -> build+scan -> dry-run -> deploy)
├── scripts/              # setup.sh / destroy.sh
└── .kube-linter.yaml     # manifest lint config used by CI
```

## Prerequisites

| Tool      | Tested version | Notes                          |
|-----------|----------------|--------------------------------|
| Docker    | 24+            | kind runs nodes as containers  |
| Terraform | 1.5+           | OpenTofu 1.6+ also works       |
| kind      | 0.22+          | needed for `kind load`         |
| kubectl   | 1.29+          |                                |

8 GB free RAM recommended (Prometheus stack included).

## Quick start (one command)

```bash
./scripts/setup.sh
```

That script runs the same four steps described below. Total time on a laptop:
about 5 to 7 minutes, most of it pulling the monitoring images.

## Step-by-step

**1. Provision the cluster, namespaces and monitoring stack**

```bash
cd terraform
terraform init
terraform plan     # review before applying
terraform apply
export KUBECONFIG=~/.kube/devops-assessment-config
kubectl get nodes  # one control-plane node, Ready
```

**2. Build the application image and load it into kind**

```bash
docker build -t hello-web:1.0.0 app/
kind load docker-image hello-web:1.0.0 --name devops-assessment
```

**3. Deploy the two-tier app (dry-run first)**

```bash
kubectl apply -f k8s/ --dry-run=server   # validates against the API server
kubectl apply -f k8s/
kubectl -n demo-app rollout status statefulset/postgres
kubectl -n demo-app rollout status deployment/hello-web
```

**4. Verify**

```bash
curl http://localhost:8080/          # {"message":"Hello World...","visits":1}
curl http://localhost:8080/readyz    # DB connectivity check
kubectl -n demo-app get pvc          # Bound PVC backing Postgres
```

Persistence proof: `kubectl -n demo-app delete pod postgres-0`, wait for the
StatefulSet to recreate it, curl `/` again. The visit counter continues, it
does not reset.

## Monitoring

Grafana: http://localhost:3000 (user `admin`, password `admin123`, lab only).
Useful built-in dashboards: "Kubernetes / Compute Resources / Namespace (Pods)"
filtered to `demo-app`, and "Node Exporter / Nodes" for cluster health.

Prometheus, if you want raw queries:

```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
```

## CI/CD pipeline

Workflow: [.github/workflows/ci-cd.yaml](.github/workflows/ci-cd.yaml)

1. **validate** - kube-linter on `k8s/`, hadolint on the Dockerfile
2. **build** - docker build, Trivy scan (fails on HIGH/CRITICAL)
3. **deploy** (`master`/`main` only) - ephemeral kind cluster, `kubectl apply
   --dry-run=server`, apply, rollout wait, curl smoke test

Triggers on push/PR to `master` or `main` touching `app/`, `k8s/` or the
workflow itself (`workflow_dispatch` allows manual runs). Every run starts from
a fresh cluster, so a green pipeline means the whole stack is reproducible from
scratch.

To reproduce the CI validation locally:

```bash
kube-linter lint k8s/ --config .kube-linter.yaml
docker run --rm -i hadolint/hadolint < app/Dockerfile
```

## Developer workflow (GitHub Flow with `gh`)

Changes land on `master` through short-lived feature branches and pull
requests. The whole cycle is driven from the local machine with the GitHub CLI.

Prerequisites: `gh auth login` (one-time), plus `git` and the tools above.

**1. Create a feature branch off the latest `master`**

```bash
git checkout master && git pull --ff-only origin master
git checkout -b fix/my-change master
```

**2. Make a minor change and validate it locally first**

```bash
# e.g. edit a manifest or app/app.py, then run the same gates CI will run:
kube-linter lint k8s/ --config .kube-linter.yaml
docker run --rm -i hadolint/hadolint < app/Dockerfile
```

**3. Commit and push the branch**

```bash
git add -A
git commit -m "fix: short description of the change"
git push -u origin fix/my-change
```

**4. Open the pull request**

```bash
gh pr create --base master --head fix/my-change \
  --title "fix: short description of the change" \
  --body  "What changed and why."
```

**5. Watch the feature-branch pipeline (validate + build)**

On a PR touching `app/` or `k8s/`, CI runs `validate` and `build`; `deploy` is
skipped because the ref is not `master`.

```bash
gh pr checks --watch                               # live status of the PR's checks
# or follow the run's logs directly:
gh run watch "$(gh run list --branch fix/my-change --limit 1 \
  --json databaseId --jq '.[0].databaseId')" --exit-status
```

**6. Merge — this triggers the full `master` pipeline (incl. `deploy`)**

```bash
gh pr merge fix/my-change --merge --delete-branch
git checkout master && git pull --ff-only origin master
# watch validate -> build -> deploy on the merge commit:
gh run watch "$(gh run list --workflow=ci-cd.yaml --branch master --event push \
  --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

### Running the pipeline manually (`workflow_dispatch`)

Trigger the pipeline on any branch without a push or PR — handy for validating
a branch before opening the PR, or for changes the path filters skip (the
`pull_request` trigger only watches `app/**` and `k8s/**`, so a PR that touches
*only* `.github/**` will not auto-run and should be validated this way):

```bash
gh workflow run ci-cd.yaml --ref fix/my-change   # validate + build (deploy auto-skips off master)
gh workflow run ci-cd.yaml --ref master          # full validate + build + deploy
```

### Handy inspection commands

```bash
gh pr list                                   # open PRs
gh pr view <n> --web                         # open a PR in the browser
gh run list --workflow=ci-cd.yaml --limit 5  # recent pipeline runs
gh run view <run-id>                         # per-job summary of a run
gh run view <run-id> --log-failed            # only the failed steps' logs
```

## Dockerfile security summary

Full reasoning in DESIGN.md; the short version:

- Multi-stage build: pip and its cache stay in the builder, final image ships
  only the venv and one .py file
- Runs as fixed non-root UID 10001, all Linux capabilities dropped,
  `allowPrivilegeEscalation: false`, read-only root filesystem (writable
  emptyDir mounted at /tmp only)
- Non-privileged port 8000, pinned base image and dependency versions,
  Trivy gate in CI

## Teardown

```bash
./scripts/destroy.sh
```
