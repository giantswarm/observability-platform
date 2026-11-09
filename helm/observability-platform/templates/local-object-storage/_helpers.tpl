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
