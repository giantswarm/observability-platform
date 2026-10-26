#!/usr/bin/env bash
# Self-signed certificate for the Envoy Gateway `https` listener. The `signer` container
# in jwks.yaml runs it.
# Do not use this anywhere real.
#
#   tls.sh [hostname...]   writes a self-signed certificate for the hostnames, once
#
# The hostnames default to grafana.localhost and observability.localhost. The certificate
# also covers 127.0.0.1, which the app-test-suite tests connect to.
set -euo pipefail

DIR=/keys
[ $# -gt 0 ] || set -- grafana.localhost observability.localhost

mkdir -p "$DIR"
if [ ! -f "$DIR/tls.crt" ]; then
  SAN=$(printf 'DNS:%s,' "$@")IP:127.0.0.1
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$1" \
    -addext "subjectAltName=$SAN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$DIR/tls.key" -out "$DIR/tls.crt" 2>/dev/null
fi
