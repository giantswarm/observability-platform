{{/*
Local blob storage (development only).

Those are Azurite public credentials, from
https://learn.microsoft.com/azure/storage/common/storage-connect-azurite.
*/}}
{{- define "observability-platform.localBlobStorage.accountName" -}}devstoreaccount1{{- end -}}
{{- define "observability-platform.localBlobStorage.accountKey" -}}Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=={{- end -}}
{{- define "observability-platform.localBlobStorage.serviceName" -}}azurite{{- end -}}
{{- define "observability-platform.localBlobStorage.port" -}}10000{{- end -}}
