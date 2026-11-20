#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
vendor="$(cd "$here/.." && pwd)/vendor"

CHROMIUM_TAG="158.0.8127.36"
HSTS_SHA256="d132107cad8e71df05e39b042a23843ea1eba648f8206f42ab59e070e2d2486c"
out="$vendor/hsts-preload"
stamp="$CHROMIUM_TAG-$HSTS_SHA256-$(shasum -a 256 "$here/hsts-preload.py" | cut -c1-16)"
installed() { [ -f "$out/.version" ] && [ "$(cat "$out/.version")" = "$stamp" ]; }
if ! installed && [ -z "${HSTS_LOCKED:-}" ]; then
  mkdir -p "$out"
  HSTS_LOCKED=1 exec lockf -k -t 600 "$out/.lock" "$0"
fi
if ! installed; then
  json="$out/transport_security_state_static.$CHROMIUM_TAG.json"
  if [ ! -f "$json" ] || ! echo "$HSTS_SHA256  $json" | shasum -a 256 -c - >/dev/null 2>&1; then
    url="https://chromium.googlesource.com/chromium/src/+/refs/tags/$CHROMIUM_TAG/net/http/transport_security_state_static.json?format=TEXT"
    echo "Downloading $url" >&2
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$json.b64" "$url"
    base64 -d -i "$json.b64" -o "$json.part"
    rm -f "$json.b64"
    if ! echo "$HSTS_SHA256  $json.part" | shasum -a 256 -c - >&2; then
      rm -f "$json.part"
      echo "error: Chromium's HSTS preload list at $CHROMIUM_TAG doesn't match its pinned SHA-256" >&2
      exit 1
    fi
    mv "$json.part" "$json"
  fi
  rm -rf "$out/hosts.new"
  python3 -I "$here/hsts-preload.py" "$json" "$out/hosts.new"
  rm -rf "$out/hosts"
  mv "$out/hosts.new" "$out/hosts"
  echo "$stamp" > "$out/.version"
  find "$out" -maxdepth 1 -name 'transport_security_state_static.*.json' ! -name "transport_security_state_static.$CHROMIUM_TAG.json" -delete
fi
