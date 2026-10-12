#!/usr/bin/env bash
# Local CA and serving certificate for the Envoy Gateway `https` listener. `make local-up` runs it.
# Do not use this anywhere real.
#
#   tls.sh [hostname...]   writes the CA and a certificate for the hostnames, once
#
# The hostnames default to grafana.localhost and observability.localhost.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/.keys"
[ $# -gt 0 ] || set -- grafana.localhost observability.localhost

mkdir -p "$DIR"
if [ ! -f "$DIR/ca.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=observability-platform local CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$DIR/ca.key" -out "$DIR/ca.crt" 2>/dev/null
fi
if [ ! -f "$DIR/tls.crt" ]; then
  SAN=$(printf 'DNS:%s,' "$@")
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$1" \
    -keyout "$DIR/tls.key" -out "$DIR/tls.csr" 2>/dev/null
  openssl x509 -req -in "$DIR/tls.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
    -days 365 -out "$DIR/tls.crt" -extfile <(printf '%s\n' \
      "subjectAltName=${SAN%,}" \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth") 2>/dev/null
  rm -f "$DIR/tls.csr"
fi
