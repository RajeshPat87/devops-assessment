# Lead DevOps Engineer - Technical Assessment

Single-node Kubernetes cluster provisioned with Terraform (kind), running a
two-tier application (Flask + PostgreSQL) packaged as a Helm chart, with a
Prometheus/Grafana monitoring stack, deployed through a GitHub Actions pipeline.

Architecture decisions, scalability path, SPOF post-mortem and trade-offs are
in [DESIGN.md](DESIGN.md).

```
├── terraform/            # kind cluster + namespaces + kube-prometheus-stack
├── app/                  # Flask app + multi-stage Dockerfile
├── chart/                # Helm chart: ConfigMap, Secret, Postgres StatefulSet+PVC, Web Deployment
├── .github/workflows/    # ci-cd.yaml (validate -> build+scan -> dry-run -> deploy)
├── scripts/              # setup.sh / destroy.sh
└── .kube-linter.yaml     # lint config applied to the rendered chart in CI
```

## Prerequisites

| Tool      | Tested version | Notes                          |
|-----------|----------------|--------------------------------|
| Docker    | 24+            | kind runs nodes as containers  |
| Terraform | 1.5+           | OpenTofu 1.6+ also works       |
| kind      | 0.22+          | needed for `kind load`         |
| kubectl   | 1.29+          |                                |
| Helm      | 3.13+          | app is packaged as a chart     |

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

# kind merges its credentials into ~/.kube/config and selects the new context,
# so no KUBECONFIG export is needed. Existing contexts are left untouched.
kubectl config current-context   # kind-devops-assessment
kubectl get nodes                # one control-plane node, Ready
```

**2. Build the application image and load it into kind**

```bash
docker build -t hello-web:1.0.0 app/
kind load docker-image hello-web:1.0.0 --name devops-assessment
```

**3. Deploy the two-tier app with Helm (dry-run first)**

The `demo-app` namespace is already created by Terraform in step 1.

```bash
# server-side dry-run: renders the chart and validates against the API server
helm upgrade --install hello-app chart/ --namespace demo-app --dry-run=server
helm upgrade --install hello-app chart/ --namespace demo-app --wait --timeout 180s
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

1. **validate** - `helm lint`, then kube-linter on the rendered chart, plus
   hadolint on the Dockerfile
2. **build** - docker build, Trivy scan (fails on HIGH/CRITICAL)
3. **deploy** (`master` only) - ephemeral kind cluster, `helm upgrade
   --install --dry-run=server`, then `--wait` install, curl smoke test

Triggers on push/PR to `master` touching `app/`, `chart/` or the
workflow itself (`workflow_dispatch` allows manual runs). Every run starts from
a fresh cluster, so a green pipeline means the whole stack is reproducible from
scratch.

### What each validation gate checks

The `validate` job is four static gates that run before anything is built. They
are intentionally cheap and fail fast, so a broken chart or Dockerfile never
reaches the build or deploy stages.

| Gate | Tool | What it validates | Failure mode |
|------|------|-------------------|--------------|
| **Helm lint** | `helm lint chart/` | Chart structure, `Chart.yaml` metadata, template syntax, and value references. Catches malformed templates and missing required fields. | Non-zero exit on any `[ERROR]`; `[WARNING]` is reported but non-blocking. |
| **Rendered-manifest lint** | [kube-linter](https://docs.kubelinter.io/) on `helm template` output | Security and reliability posture of the *actual* objects Helm will apply: non-root, dropped capabilities, read-only rootfs, resource requests/limits, liveness/readiness probes, `imagePullPolicy`, owner labels, ServiceAccounts, etc. | Non-zero exit on any finding not listed in `.kube-linter.yaml`. |
| **Dockerfile lint** | [hadolint](https://github.com/hadolint/hadolint) | Dockerfile best practices — pinned `apt` versions (DL3008), pinned `pip` packages (DL3013), `--no-install-recommends`, cleaned apt lists (DL3009), no `latest` tags, no `root` at runtime, single-purpose `RUN` layers. | Non-zero exit on any rule violation above the configured threshold. |
| **Image scan** | [Trivy](https://trivy.dev/) (in `build`) | OS/library CVEs in the built image. `severity: HIGH,CRITICAL`, `ignore-unfixed: true`, `exit-code: 1`. | Fails the build on any fixable HIGH/CRITICAL CVE. |

Why kube-linter runs on the **rendered** chart rather than the raw templates:
Helm templates contain `{{ }}` directives that are not valid Kubernetes YAML on
their own. Running `helm template ... > rendered/manifests.yaml` first means the
linter inspects exactly the objects that will hit the API server — the same
bytes `helm upgrade --install` produces — so no drift between "what we linted"
and "what we deployed."

**kube-linter checks deliberately excluded** (in [`.kube-linter.yaml`](.kube-linter.yaml),
each with an inline rationale) because they don't apply to a single-node lab:

| Excluded check | Reason |
|----------------|--------|
| `run-as-non-root` | The official Postgres image must run as its own uid; the web tier still enforces `runAsNonRoot` explicitly. |
| `no-anti-affinity` / `no-node-affinity` | One node — affinity has nothing to target. |
| `minimum-three-replicas` | Three replicas can't be scheduled on one node and add no HA value here. |
| `exposed-services` | NodePort is intentional for local access; would be Ingress/LB in prod. |
| `dnsconfig-options` | Cluster uses kube-dns defaults; per-pod DNSConfig is unnecessary. |
| `non-isolated-pod` | No NetworkPolicy in the lab; traffic isolation would be added in prod. |
| `read-secret-from-env-var` | The Postgres image and the app only accept DB creds via env vars; file-mounted secrets need app changes. |
| `sorted-keys` | Key order in Helm-generated YAML is set by the templates and carries no meaning. |

To reproduce the CI validation locally:

```bash
helm lint chart/
helm template hello-app chart/ --namespace demo-app > rendered.yaml
kube-linter lint rendered.yaml --config .kube-linter.yaml
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
# e.g. edit the chart or app/app.py, then run the same gates CI will run:
helm lint chart/
helm template hello-app chart/ --namespace demo-app | kube-linter lint - --config .kube-linter.yaml
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

On a PR touching `app/` or `chart/`, CI runs `validate` and `build`; `deploy` is
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
`pull_request` trigger only watches `app/**` and `chart/**`, so a PR that touches
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

### kubectl shorthands (optional)

`scripts/kubectl-aliases.sh` defines the kubectl aliases used throughout this
repo's day-to-day work — `kgp` (get pods), `klf` (logs -f), `krr` (rollout
restart deployment), `kge` (events, newest last), and about 40 more.

```bash
source scripts/kubectl-aliases.sh                             # this shell only
echo "source $PWD/scripts/kubectl-aliases.sh" >> ~/.bashrc    # every new shell
```

Source it, do not execute it: aliases defined by a script that runs in a
subshell disappear the moment it exits. The script checks for this and tells
you so rather than silently doing nothing.

These aliases are a convenience for interacting with the cluster by hand.
Nothing in the repo depends on them — `setup.sh`, `destroy.sh` and CI never
call `kubectl` through an alias.

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

## Appendix: validation errors encountered (and how they were fixed)

Recorded here for documentation and future reference. These are the concrete
failures that the gates above (and the deploy job) caught while building this
project, each traceable to the commit that resolved it.

### hadolint — `DL3008` unpinned apt versions

```
app/Dockerfile:24 DL3008 warning: Pin versions in apt get install.
  Instead of `apt-get install <package>` use `apt-get install <package>=<version>`
```

**Cause:** `apt-get install -y --no-install-recommends libpq5 curl` installed
whatever candidate versions the base image happened to resolve, so builds were
not reproducible.
**Fix:** pinned `libpq5=17.10-0+deb13u1` and `curl=8.14.1-2+deb13u3` to the
current `python:3.12-slim` (Debian 13) candidates. hadolint then reported zero
findings. _(commit `04febe3`)_




### kube-linter — multiple findings on the raw manifests

The first render tripped several kube-linter checks at once:

```
- (sorted-keys) object has keys that are not sorted
- (required-label-owner) object does not have the "owner" label
- (no-read-only-root-fs) container "postgres" does not have a read-only root filesystem
- (default-service-account) object uses the default service account
- (unset-restart-policy) restartPolicy is not set to "Always"
```

**Fix (commit `93495de`):**
- Sorted all manifest keys alphabetically.
- Added an `owner` label + `email` annotation to every workload.
- Added dedicated ServiceAccounts for `postgres` and `hello-web`.
- Enabled a read-only root filesystem on Postgres with writable `emptyDir`
  mounts for the paths it must write to.
- Set an explicit `restartPolicy: Always` and a StatefulSet
  `updateStrategy: RollingUpdate`.
- Excluded the checks that don't apply to a single-node lab, each with an inline
  rationale (see the table above).

### Runtime — Postgres crash-loop under a read-only rootfs

After the security hardening above, the deploy job's Postgres pod crash-looped:

```
chown: /var/lib/postgresql/data/pgdata: Operation not permitted
```

**Cause:** the container dropped ALL capabilities but had no `runAsUser`, so it
started as root. The Postgres entrypoint, when root, `chown`s `PGDATA` before
dropping privileges — which needs `CAP_CHOWN` and therefore failed. `fsGroup`
was also `999` (the Debian image's postgres GID) while the manifest uses the
Alpine image, where postgres is uid/gid `70`.
**Fix (commit `bf5c420`):** run the pod directly as postgres (`runAsUser`/
`runAsGroup: 70`, `runAsNonRoot: true`) so the entrypoint skips the privileged
`chown`, and set `fsGroup: 70` so the PVC and `emptyDir` volumes are
group-writable. Verified in kind: `postgres 1/1`, `hello-web 2/2`, smoke test
green with a working visit counter.

### CI — Trivy action pinned to non-existent tags

The `build` job failed at setup on every run:

```
Unable to resolve action `aquasecurity/trivy-action@0.24.0`, unable to find version `0.24.0`
```

**Cause / fix:** tags are `v`-prefixed, so `@0.24.0` never existed
(commit `3d12f70`). `v0.28.0`–`v0.30.0` then failed because they internally
referenced a deleted `setup-trivy` tag; pinned to `v0.36.0`, which references
`setup-trivy` by commit SHA and survives upstream tag deletions (commit
`8a89173`).

### CI — pipeline never triggered on `master`

The workflow only watched `main`, but the repo's default branch is `master`, so
push / pull_request / deploy never fired.
**Fix (commit `5859858`):** watch `master` for push and pull_request, gate
`deploy` on `master`, and add `workflow_dispatch` for manual validation.
