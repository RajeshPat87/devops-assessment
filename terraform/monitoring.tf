# Observability: kube-prometheus-stack (Prometheus + Grafana + Alertmanager
# + node-exporter + kube-state-metrics) installed as one Helm release.
# Values are trimmed for a single-node lab: no persistence for Prometheus,
# reduced retention, Grafana exposed on NodePort 30300 (host port 3000).

resource "helm_release" "kube_prometheus_stack" {
  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kps_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  set {
    name  = "grafana.service.type"
    value = "NodePort"
  }
  set {
    name  = "grafana.service.nodePort"
    value = "30300"
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "2d"
  }
  # Keep the lab light: skip persistence, cap Prometheus resources.
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }
}
