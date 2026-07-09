variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "devops-assessment"
}

variable "kubernetes_version" {
  description = "kindest/node image tag (Kubernetes version)"
  type        = string
  default     = "v1.29.2"
}

variable "kubeconfig_path" {
  description = "Where to write the kubeconfig for this cluster"
  type        = string
  default     = "~/.kube/devops-assessment-config"
}

variable "app_namespace" {
  description = "Namespace for the two-tier application"
  type        = string
  default     = "demo-app"
}

variable "kps_chart_version" {
  description = "kube-prometheus-stack chart version"
  type        = string
  default     = "58.2.2"
}

variable "grafana_admin_password" {
  description = "Grafana admin password (lab only, do not reuse anywhere)"
  type        = string
  default     = "admin123"
  sensitive   = true
}
