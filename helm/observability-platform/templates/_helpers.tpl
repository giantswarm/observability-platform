{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "labels.common" -}}
app: {{ include "name" . | quote }}
{{ include "labels.selector" . }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | quote }}
helm.sh/chart: {{ include "chart" . | quote }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "labels.selector" -}}
app.kubernetes.io/name: {{ include "name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{/*
Object storage validation.

The fixed Secret name and the container names live in values.schema.json, which
rejects bad values before any template runs. The account name is required exactly
when Mimir or Loki is enabled. A schema cannot express that against sibling
toggles. Disabling both keeps rendering an empty release.
*/}}
{{- define "observability-platform.objectStorage.validate" -}}
{{- if not .Values.global.objectStorage.azure.accountName -}}
{{- fail "global.objectStorage.azure.accountName is empty. Set it to the Azure storage account holding the containers - see doc/OBJECT_STORAGE.md." -}}
{{- end -}}
{{- end -}}