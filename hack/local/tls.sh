#!/usr/bin/env bash
# Self-signed certificate for the Envoy Gateway `https` listener. `make local-up` runs it.
# Do not use this anywhere real.
#
#   tls.sh [hostname...]   writes a self-signed certificate for the hostnames, once
#
# The hostnames default to grafana.localhost and observability.localhost.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/.keys"
[ $# -gt 0 ] || set -- grafana.localhost observability.localhost

mkdir -p "$DIR"
if [ ! -f "$DIR/tls.crt" ]; then
  SAN=$(printf 'DNS:%s,' "$@")
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$1" \
    -addext "subjectAltName=${SAN%,}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$DIR/tls.key" -out "$DIR/tls.crt" 2>/dev/null
fi
