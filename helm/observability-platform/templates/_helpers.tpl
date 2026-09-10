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

Everything unconditional - the fixed Secret name, the container names - is in
values.schema.json, which rejects bad values before any template runs. What is left here
is conditional on sibling values, which a schema cannot express: the account name is
required exactly when Mimir or Loki is enabled, and `localBlobStorage.enabled` computes
both the account name and the connection string, so either one set by hand beside it would
be silently ignored. Disabling both components has to keep rendering an empty release.
*/}}
{{- define "observability-platform.objectStorage.validate" -}}
{{- $azure := .Values.global.objectStorage.azure -}}
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
{{- end -}}

{{/*
Local blob storage (development only).

The well-known Azurite account and key, from
https://learn.microsoft.com/azure/storage/common/storage-connect-azurite. Both are public
fixed constants, not credentials to protect. Each is defined once because the init Job and
the connection string below have to agree on them, and so do the Service and the port in
that connection string.
*/}}
{{- define "observability-platform.localBlobStorage.accountName" -}}devstoreaccount1{{- end -}}
{{- define "observability-platform.localBlobStorage.accountKey" -}}Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=={{- end -}}
{{- define "observability-platform.localBlobStorage.serviceName" -}}azurite{{- end -}}
{{- define "observability-platform.localBlobStorage.port" -}}10000{{- end -}}

{{/*
Storage account name delivered to Mimir and Loki.
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

Empty on the real-Azure path, where both clients derive `https://<account>.<suffix>` and
ignore this. For the emulator it is the only way to reach the endpoint at all, because
that derivation hardcodes https and puts the account in the host name. The account name
repeats in the BlobEndpoint path deliberately: that is what makes the URL path-style,
which is also why the Deployment passes --disableProductStyleUrl.
*/}}
{{- define "observability-platform.objectStorage.connectionString" -}}
{{- if .Values.localBlobStorage.enabled -}}
{{- $account := include "observability-platform.localBlobStorage.accountName" . -}}
{{- printf "DefaultEndpointsProtocol=http;AccountName=%s;AccountKey=%s;BlobEndpoint=http://%s.%s.svc.cluster.local:%s/%s;" $account (include "observability-platform.localBlobStorage.accountKey" .) (include "observability-platform.localBlobStorage.serviceName" .) .Release.Namespace (include "observability-platform.localBlobStorage.port" .) $account -}}
{{- else -}}
{{- .Values.global.objectStorage.azure.connectionString -}}
{{- end -}}
{{- end -}}
