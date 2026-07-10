# Grafana — Day-to-Day Cluster Usage Dashboard

A ready-to-import Grafana dashboard for tracking day-to-day Kubernetes usage
(CPU, memory, network, disk, pod health) on the local **kind** cluster.

- **File:** [`k8s-daily-usage-dashboard.json`](./k8s-daily-usage-dashboard.json)
- **Dashboard title:** _Kubernetes — Day-to-Day Cluster Usage_ (`uid: k8s-daily-usage`)
- **Data source:** any **Prometheus** (installed by `kube-prometheus-stack`)

## Where the data comes from

Everything is self-hosted **inside the kind cluster** — no cloud provider involved.
`terraform/monitoring.tf` installs the `kube-prometheus-stack` Helm chart, which brings up:

```
kind cluster (Docker, local)
├─ kubelet/cAdvisor    → container_*  (CPU / mem / network per container)
├─ node-exporter       → node_*       (node CPU / mem / disk)          [DaemonSet]
├─ kube-state-metrics  → kube_*       (pod / node / restart state)
│        │  (Prometheus scrapes all three, stores locally)
├─ Prometheus  ───────► time-series store
│        │
└─ Grafana (NodePort 30300 → localhost:3000) ──► queries Prometheus, renders panels
```

The dashboard uses **only** these three metric families, so it drops straight into
the stack with no extra configuration.

## Bring up the stack (if not already running)

```bash
# From the repo root — provisions kind cluster + monitoring + app
./scripts/setup.sh
```

## Access Grafana

```bash
# Option A: the chart exposes Grafana on NodePort 30300 (mapped to host port 3000)
#   → open http://localhost:3000 directly

# Option B: port-forward the Grafana service (release "kps", namespace "monitoring")
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
#   → open http://localhost:3000
```

**Login:** user `admin`, password = the `grafana_admin_password` Terraform variable
(see `terraform/variables.tf` / your `terraform.tfvars`).

## Import the dashboard

1. In Grafana: **Dashboards → New → Import**.
2. Click **Upload dashboard JSON file** and choose
   `monitoring/grafana/k8s-daily-usage-dashboard.json`
   (or paste the file contents into the text box).
3. When prompted, select your **Prometheus** data source.
4. Click **Import**.

The dashboard opens with a 24h range and a 30s refresh.

## Using it

Template variables at the top:

| Variable      | Purpose                                            |
| ------------- | -------------------------------------------------- |
| `datasource`  | Pick which Prometheus to query                     |
| `namespace`   | Filter panels to one/many namespaces (default All) |
| `node`        | Filter node panels (default All)                   |

Panel groups:

- **Cluster Overview** — nodes ready, running pods, pods not running, CPU cores used, memory used, active namespaces + CPU/memory utilization gauges.
- **Compute Usage by Namespace** — CPU (cores) and memory time series, stacked.
- **Node Usage** — per-node CPU %, memory %, root disk %.
- **Network & Reliability** — network RX/TX by namespace, pod restarts per hour, and Top-10 pods by CPU / by memory.

## Notes for kind

- The **Node Root Disk Utilization %** panel avoids a hard-coded `mountpoint="/"`
  (which kind nodes often don't expose) — it takes the largest real filesystem per
  node instead, so it works out of the box on kind.
- This is **not** an Azure setup. Azure Monitor / Azure Managed Grafana / Azure
  Managed Prometheus apply only to an **AKS** cluster — they have no role with kind.
  If this workload later moves to AKS, you could optionally swap the self-hosted
  stack for those managed services; on kind, self-hosted (the current setup) is the
  right choice.
