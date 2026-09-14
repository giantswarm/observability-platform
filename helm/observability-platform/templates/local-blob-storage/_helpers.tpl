{{/*
Local blob storage (development only).

The well-known Azurite account and key, from
https://learn.microsoft.com/azure/storage/common/storage-connect-azurite. Both are public
fixed constants, not credentials to protect. Each is defined once because the init Job and
the connection string in the chart's own _helpers.tpl have to agree on them, and so do the
Service and the port in that connection string.
*/}}
{{- define "observability-platform.localBlobStorage.accountName" -}}devstoreaccount1{{- end -}}
{{- define "observability-platform.localBlobStorage.accountKey" -}}Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=={{- end -}}
{{- define "observability-platform.localBlobStorage.serviceName" -}}azurite{{- end -}}
{{- define "observability-platform.localBlobStorage.port" -}}10000{{- end -}}
