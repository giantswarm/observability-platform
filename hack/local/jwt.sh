#!/usr/bin/env bash
# Local JWT issuer for the external API. `make local-up` and `make local-token` run it.
# Do not use this anywhere real.
#
#   jwt.sh jwks    writes the signing key and its JWKS, once
#   jwt.sh token   prints a token valid for one hour
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/.keys"
ISSUER=http://jwks.jwt-issuer.svc.cluster.local

b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

case "${1:-}" in
  jwks)
    mkdir -p "$DIR"
    [ -f "$DIR/key.pem" ] || openssl genrsa -out "$DIR/key.pem" 2048 2>/dev/null
    N=$(openssl rsa -in "$DIR/key.pem" -noout -modulus | cut -d= -f2 | xxd -r -p | b64url)
    printf '{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"dev","n":"%s","e":"AQAB"}]}' "$N" \
      > "$DIR/jwks.json"
    ;;
  token)
    NOW=$(date +%s)
    HEADER=$(printf '{"alg":"RS256","typ":"JWT","kid":"dev"}' | b64url)
    PAYLOAD=$(printf '{"iss":"%s","sub":"dev-agent","iat":%d,"exp":%d}' "$ISSUER" "$NOW" "$((NOW + 3600))" | b64url)
    SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$DIR/key.pem" -binary | b64url)
    echo "$HEADER.$PAYLOAD.$SIGNATURE"
    ;;
  *)
    echo "usage: $0 jwks|token" >&2
    exit 1
    ;;
esac
