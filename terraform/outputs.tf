output "cluster_name" {
  value = kind_cluster.this.name
}

output "kubeconfig_path" {
  value = kind_cluster.this.kubeconfig_path
}

output "app_namespace" {
  value = kubernetes_namespace.app.metadata[0].name
}

output "web_app_url" {
  value       = "http://localhost:8080"
  description = "Hello World web service (NodePort 30080 mapped to host 8080)"
}

output "grafana_url" {
  value       = "http://localhost:3000"
  description = "Grafana (NodePort 30300 mapped to host 3000, user: admin)"
}
