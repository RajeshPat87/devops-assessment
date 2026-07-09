# DESIGN.md

## 1. Architectural Choices

**kind + Terraform for the cluster.** The task asks for a single-node cluster provisioned through IaC. I picked kind (Kubernetes in Docker) with the `tehcyx/kind` Terraform provider over minikube or k3s for one reason: everything stays declarative in a single `terraform apply`. The same apply also creates the namespaces and installs the monitoring stack through the Helm provider, so there is no "run terraform, then run these five manual commands" gap. kind is also what most CI systems use for ephemeral clusters, which let me reuse the exact same setup in the GitHub Actions pipeline.

**Flask + PostgreSQL as the two tiers.** The web tier is deliberately small (one file) so the review can focus on the Kubernetes and pipeline work, not application code. It still does real work: it writes a visit counter to Postgres, which proves the PVC actually persists data. Delete the postgres pod, let the StatefulSet recreate it, and the counter continues from where it was. That is a 30-second persistence demo during the live review.

**StatefulSet for Postgres, Deployment for the web tier.** Databases want stable network identity and per-replica storage, which is exactly what a StatefulSet with `volumeClaimTemplates` gives. The web tier is stateless, so a Deployment with 2 replicas and a `maxUnavailable: 0` rolling update gives zero-downtime deploys even on this small setup.

**ConfigMap vs Secret split.** Everything non-sensitive (greeting, DB host/port/name) sits in a ConfigMap and is injected with `envFrom`. Credentials sit in a Secret and are injected per-key. The Secret is committed to git only because this is a self-contained lab that must be reproducible from scratch. Section 4 covers what I would do instead in a real repo.

**kube-prometheus-stack for observability.** K9s and Lens are viewers, not monitoring. Prometheus + Grafana gives actual scraping, dashboards, and the option to alert. One Helm release installs Prometheus, Grafana, node-exporter and kube-state-metrics. Grafana is exposed on a NodePort mapped to `localhost:3000` so it works without an Ingress controller. Alertmanager is disabled and Prometheus retention is 2 days because a single-node lab does not need either; both are one-line changes to turn back on.

**GitHub Actions for CI/CD.** Three jobs: validate (kube-linter + hadolint), build + scan (docker build + Trivy failing on HIGH/CRITICAL), and deploy (server-side dry-run, apply, rollout wait, curl smoke test). The deploy job spins up its own kind cluster so every pipeline run is reproducible with zero standing infrastructure. My day-to-day background is Azure DevOps; I chose GitHub Actions here because the repo lives on GitHub and the reviewer can see runs without any external service.

## 2. Dockerfile Security Choices

The requirement was least privilege plus a multi-stage build. What I did and why:

**Multi-stage build.** Stage 1 (`builder`) creates a virtualenv and installs dependencies. Stage 2 (`runtime`) copies only the finished venv and one .py file. pip itself, its cache, and any build metadata never exist in the final image. Result: smaller image (roughly 150MB vs 400MB+ for a naive single-stage build with build deps) and a smaller attack surface, since there is no package manager tooling for an attacker to abuse post-compromise. The only OS package added at runtime is `libpq5`, which psycopg2 needs, plus curl for the container HEALTHCHECK.

**Non-root, fixed UID.** `USER 10001:10001` with a nologin shell. A fixed numeric UID (rather than a name) lets Kubernetes verify `runAsNonRoot: true` at admission time without inspecting the image. If the process is compromised, the attacker lands as an unprivileged user, not root.

**Non-privileged port.** The app listens on 8000, not 80, so the container never needs `CAP_NET_BIND_SERVICE`. That allows the pod spec to drop ALL capabilities, which it does.

**Defense in depth at the pod level.** The Dockerfile choices are reinforced in `k8s/web-deployment.yaml`: `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `readOnlyRootFilesystem: true` (with a writable emptyDir mounted only at /tmp), and `seccompProfile: RuntimeDefault`. The image is built to survive a read-only root filesystem: no runtime writes outside /tmp, `PYTHONDONTWRITEBYTECODE=1` so Python never tries to write .pyc files.

**Pinned versions everywhere.** Base image tag (`python:3.12-slim`), every pip dependency, and the Postgres image are pinned. Unpinned tags make builds non-reproducible and let a CVE-carrying update slip in silently. The Trivy step in CI then gates HIGH/CRITICAL CVEs on every build.

What I deliberately did not do: a distroless or scratch final image. It would shrink the image further, but it removes the shell and curl, which kills the Docker HEALTHCHECK and makes live debugging during the review harder. For production I would revisit distroless and move the health check fully to Kubernetes probes (which the deployment already has).

## 3. Scalability: Single Node to Production HA

The path from this lab to production is mostly about replacing pieces, not redesigning:

**Control plane and nodes.** Swap kind for a managed control plane (AKS/EKS/GKE) via Terraform. Three-plus nodes spread across availability zones, with node pools separated by workload type (system, app, monitoring). Cluster Autoscaler or Karpenter for node scaling. Most of the Terraform structure survives; only the `kind_cluster` resource is replaced by the managed cluster module, which is why I kept providers and namespaces in Terraform rather than shell scripts.

**Web tier.** Add an HPA on CPU/memory (or custom metrics from Prometheus), a PodDisruptionBudget, and topology spread constraints across zones. Replace the NodePort with an Ingress (or Gateway API) behind a cloud load balancer, with cert-manager for TLS.

**Database tier.** A single Postgres pod does not belong in production. Two realistic options: a managed service (Azure Database for PostgreSQL Flexible Server, RDS), which is what I would pick by default, or CloudNativePG / a Postgres operator in-cluster if there is a hard requirement to self-host, giving streaming replication, automated failover and PITR backups.

**Storage.** local-path provisioner becomes a cloud CSI driver (Azure Disk, EBS) with a StorageClass that supports volume expansion and snapshots.

**Monitoring.** Enable Alertmanager with real routes (PagerDuty/Teams), persistent storage for Prometheus, and either Thanos or a managed offering (Azure Monitor managed Prometheus, AMP) for long-term retention across clusters.

## 4. Failure Analysis (Post-Mortem): the Postgres Pod as SPOF

The obvious SPOF is the node itself, but that is inherent to the task. The more interesting SPOF, because it survives even after you add nodes, is the single-replica PostgreSQL StatefulSet. If that pod dies, the web tier's `/readyz` starts failing, both web replicas drop out of their Service endpoints, and the whole application is down even though the web tier is perfectly healthy.

**Mitigation.** Short term: tune probes and set `terminationGracePeriodSeconds` correctly so restarts are fast, and rely on the PVC so no data is lost across restarts (already the case here). Real fix: move to CloudNativePG with one primary and two replicas plus automated failover, or hand the problem to a managed HA database. Also worth adding: a PgBouncer layer so the web tier survives brief failovers with connection retries instead of 500s, and an app-level retry with backoff on connection errors.

**Debugging it during peak load.** My sequence, roughly in order of cost:

1. `kubectl -n demo-app get pods -o wide` and `kubectl describe pod postgres-0`. Look at restarts, last state, and events. During peak load the usual suspect is OOMKilled (exit code 137), because the pod has a 512Mi memory limit.
2. `kubectl logs postgres-0 --previous` for the crash reason, and `kubectl top pod -n demo-app` (or the Grafana pod-resources dashboard) to compare actual usage against limits.
3. Check whether it is the DB or the disk: `kubectl get pvc -n demo-app`, events on the PV, and node-level pressure (`kubectl describe node` for MemoryPressure/DiskPressure).
4. If Postgres is up but slow: connection saturation. `SELECT count(*) FROM pg_stat_activity;` against `max_connections`, and check for lock pileups in `pg_locks`. Two gunicorn workers x 2 replicas is small, but a retry storm after a blip can still pile up connections.
5. Immediate remediation depending on the finding: raise the memory limit and let the StatefulSet restart it, scale the web tier down to shed load, or add PgBouncer. Then write the actual post-mortem: what page fired (this is why Prometheus alert rules on pod restarts and connection counts matter), timeline, root cause, and the permanent fix from the mitigation list above.

## 5. Trade-offs

**Secret committed to git.** Wrong for anything real, done here so a reviewer can reproduce everything from a clone. Production answer: External Secrets Operator pulling from Azure Key Vault (my usual setup, with Workload Identity so there are no stored credentials at all), or Sealed Secrets/SOPS if the platform must stay self-contained.

**Plain manifests instead of Helm/Kustomize.** Five YAML files are easier to review than a chart. The moment there is a second environment, I would move to Kustomize overlays (base + dev/staging/prod patches) or a Helm chart. The pipeline already lints with kube-linter, so swapping in `helm lint` is trivial.

**Push-based CI/CD instead of GitOps.** kubectl apply from the pipeline is simple and visible for a demo. At enterprise scale I prefer pull-based GitOps: ArgoCD watching an environment repo, with the CI pipeline only building/scanning images and bumping the image tag via PR. That removes cluster credentials from CI entirely and gives drift detection for free.

**No NetworkPolicies, no mTLS.** On a single-node lab they add noise without demonstrating much. First security additions for production: default-deny NetworkPolicy per namespace with an explicit web-to-postgres allow, plus Pod Security Admission set to `restricted`.

**Ephemeral CI cluster vs a long-lived target.** The deploy job creates its own kind cluster, which means CI never touches my laptop's cluster. The cost is that CI proves "the manifests deploy cleanly on a fresh cluster" rather than "production was updated". For this assessment that is the right trade; the enterprise version is below.

## 6. Reflection: Single Developer to Dev/Staging/Prod Enterprise Pipeline

What changes when this pipeline grows up:

**Branching and promotion.** Trunk-based development. PRs run validate + build + Trivy + deploy-to-ephemeral (exactly today's pipeline). Merge to main deploys to Dev automatically. Promotion to Staging and Prod happens by promoting the same immutable image digest, never rebuilding.

**Environments as code.** Kustomize overlays or Helm values per environment, in either the same repo or a dedicated config repo. Environment-specific settings (replicas, resources, hostnames) live in overlays; the base stays identical everywhere.

**GitOps for CD.** ArgoCD per cluster syncing from the config repo. CI's job shrinks to build, test, scan, sign (cosign), push to a registry, and open a PR bumping the tag in the Dev overlay. Promotion to Staging/Prod is a PR from one overlay to the next, which gives approvals, audit trail and rollback (git revert) for free.

**Gates and controls.** Staging gets integration and load tests plus a soak period. Prod requires manual approval through protected environments, deploys progressively (Argo Rollouts canary with Prometheus-based analysis), and auto-rolls-back on SLO burn. Add OPA/Conftest policy checks in CI so "no resource limits" or "image not from our registry" fails before it ever reaches a cluster.

**Identity and secrets.** OIDC federation from the pipeline to the cloud (no long-lived credentials in CI), External Secrets in every cluster, and per-environment service accounts with least-privilege RBAC instead of cluster-admin kubeconfigs.
