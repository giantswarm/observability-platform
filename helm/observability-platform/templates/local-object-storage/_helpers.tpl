{{/*
Local object store (development only).

Those are Azurite public credentials, from
https://learn.microsoft.com/azure/storage/common/storage-connect-azurite.
*/}}
{{- define "observability-platform.azurite.accountName" -}}devstoreaccount1{{- end -}}
{{- define "observability-platform.azurite.accountKey" -}}Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=={{- end -}}
{{- define "observability-platform.azurite.serviceName" -}}azurite{{- end -}}
{{- define "observability-platform.azurite.port" -}}10000{{- end -}}

{{/*
Azurite host and port, shared by the Mimir and Loki connection string and the Tempo
endpoint suffix.
*/}}
{{- define "observability-platform.azurite.host" -}}
{{- printf "%s.%s.svc.cluster.local:%s" (include "observability-platform.azurite.serviceName" .) .Release.Namespace (include "observability-platform.azurite.port" .) -}}
{{- end -}}

{{/*
Garage dev key and RPC secret. Development only, public on purpose, like the Azurite
key above. Garage needs an access key ID of 8+ characters of [A-Za-z0-9-_.], a secret
key of 16+ printable characters and an RPC secret of 64 hex characters.
*/}}
{{- define "observability-platform.garage.accessKeyId" -}}GKobservabilityplatformdev{{- end -}}
{{- define "observability-platform.garage.secretAccessKey" -}}observability-platform-dev-secret-key{{- end -}}
{{- define "observability-platform.garage.rpcSecret" -}}0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef{{- end -}}
{{- define "observability-platform.garage.serviceName" -}}garage{{- end -}}
{{- define "observability-platform.garage.port" -}}3900{{- end -}}
{{- define "observability-platform.garage.rpcPort" -}}3901{{- end -}}
{{- define "observability-platform.garage.region" -}}garage{{- end -}}

{{/*
Garage S3 host and port, delivered to Mimir, Loki and Tempo as the S3 endpoint.
*/}}
{{- define "observability-platform.garage.host" -}}
{{- printf "%s.%s.svc.cluster.local:%s" (include "observability-platform.garage.serviceName" .) .Release.Namespace (include "observability-platform.garage.port" .) -}}
{{- end -}}
