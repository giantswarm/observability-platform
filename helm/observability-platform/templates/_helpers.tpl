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
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimAll "-._" -}}
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
*/}}
{{- define "observability-platform.objectStorage.validate" -}}
{{- $os := .Values.global.objectStorage -}}
{{- $backend := $os.backend | default "" -}}
{{- if not (has $backend (list "azure" "s3")) -}}
{{- fail (printf "global.objectStorage.backend is %q. Set it to \"azure\" or \"s3\" - see doc/OBJECT_STORAGE.md." $backend) -}}
{{- end -}}
{{- if eq $backend "azure" -}}
{{- $azure := $os.azure -}}
{{- if .Values.localBlobStorage.enabled -}}
{{- if $azure.accountName -}}
{{- fail (printf "localBlobStorage.enabled is true, so storage is the in-cluster Azurite emulator under account %q, but global.objectStorage.azure.accountName is set to %q - which nothing would read. Unset one of the two - see doc/LOCAL_DEV.md." (include "observability-platform.localBlobStorage.accountName" .) $azure.accountName) -}}
{{- end -}}
{{- if $azure.connectionString -}}
{{- fail "localBlobStorage.enabled is true, which computes the connection string for the in-cluster emulator, but global.objectStorage.azure.connectionString is set as well and would be ignored. Unset one of the two - see doc/LOCAL_DEV.md." -}}
{{- end -}}
{{- else if not (or $azure.accountName $azure.connectionString) -}}
{{- fail "global.objectStorage.azure.accountName is empty. Set it to the Azure storage account holding the containers, or set global.objectStorage.azure.connectionString to reach an endpoint of your own, or set localBlobStorage.enabled to run against a local Azurite emulator - see doc/OBJECT_STORAGE.md." -}}
{{- end -}}
{{- if and .Values.tempo.enabled $azure.connectionString (not .Values.localBlobStorage.enabled) -}}
{{- fail "tempo.enabled is true and global.objectStorage.azure.connectionString is set. Tempo reads no connection string: it needs global.objectStorage.azure.accountName and the account key in the credentials Secret. Set accountName instead of connectionString, or set tempo.enabled to false - see doc/OBJECT_STORAGE.md." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Storage account name delivered to Mimir, Loki and Tempo.
*/}}
{{- define "observability-platform.objectStorage.accountName" -}}
{{- if .Values.localBlobStorage.enabled -}}
{{- include "observability-platform.localBlobStorage.accountName" . -}}
{{- else -}}
{{- .Values.global.objectStorage.azure.accountName -}}
{{- end -}}
{{- end -}}

{{/*
Connection string delivered to Mimir and Loki.
*/}}
{{- define "observability-platform.objectStorage.connectionString" -}}
{{- if .Values.localBlobStorage.enabled -}}
{{- $account := include "observability-platform.localBlobStorage.accountName" . -}}
{{- printf "DefaultEndpointsProtocol=http;AccountName=%s;AccountKey=%s;BlobEndpoint=http://%s/%s;" $account (include "observability-platform.localBlobStorage.accountKey" .) (include "observability-platform.localBlobStorage.host" .) $account -}}
{{- else -}}
{{- .Values.global.objectStorage.azure.connectionString -}}
{{- end -}}
{{- end -}}

{{/*
Azure Blob endpoint suffix delivered to Tempo. Tempo switches to Azurite path style
when the suffix does not start with `blob.`.
*/}}
{{- define "observability-platform.objectStorage.endpointSuffix" -}}
{{- if .Values.localBlobStorage.enabled -}}
{{- include "observability-platform.localBlobStorage.host" . -}}
{{- else -}}
blob.core.windows.net
{{- end -}}
{{- end -}}
