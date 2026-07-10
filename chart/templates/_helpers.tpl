{{/*
Labels shared by every resource in the chart. Per-resource identity
(app.kubernetes.io/name) is added at each template so selectors stay stable.
*/}}
{{- define "hello-app.commonLabels" -}}
app.kubernetes.io/part-of: demo-app
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}
