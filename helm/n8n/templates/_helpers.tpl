{{- define "n8n.name" -}}
n8n
{{- end -}}

{{- define "n8n.fullname" -}}
{{ .Release.Name }}-n8n
{{- end -}}

{{- define "n8n.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "n8n.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: Helm
{{- end -}}

{{- define "n8n.selectorLabels" -}}
app.kubernetes.io/name: {{ include "n8n.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* UID of the non‑root user */ -}}
{{- define "n8n.uid" -}}
1000
{{- end -}}
