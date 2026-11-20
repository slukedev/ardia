#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
vendor="$(cd "$here/.." && pwd)/vendor"

UBOL_VERSION="2026.1116.1650"
UBOL_SHA256="eed328928569264b321d9fc162c19a68167db54e36c1be51328d5739439907b4"
UBOL_CHROMIUM_SHA256="67e084b34470c51c08fa9314b118b8cb73df3a72e90c6a3b536d041c92e61bbc"
ubol="$vendor/ubol-webkit"
stamp="$UBOL_VERSION-$(shasum -a 256 "$here/ubol-webkit.py" | cut -c1-16)"
installed() { [ -f "$ubol/.version" ] && [ "$(cat "$ubol/.version")" = "$stamp" ]; }
if ! installed && [ -z "${UBOL_LOCKED:-}" ]; then
  mkdir -p "$ubol"
  UBOL_LOCKED=1 exec lockf -k -t 600 "$ubol/.lock" "$0"
fi
fetch() {
  local zip="$ubol/uBOLite_$UBOL_VERSION.$1.zip"
  if [ ! -f "$zip" ]; then
    local url="https://github.com/uBlockOrigin/uBOL-home/releases/download/$UBOL_VERSION/uBOLite_$UBOL_VERSION.$1.zip"
    echo "Downloading $url" >&2
    curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$zip.part" "$url" || return 1
    mv "$zip.part" "$zip" || return 1
  fi
  if ! echo "$2  $zip" | shasum -a 256 -c - >&2; then
    rm -f "$zip"
    echo "error: $zip doesn't match its pinned SHA-256; removed it so the next build downloads it again" >&2
    return 1
  fi
  echo "$zip"
}
if ! installed; then
  safari="$(fetch safari "$UBOL_SHA256")"
  chromium="$(fetch chromium "$UBOL_CHROMIUM_SHA256")"
  rm -rf "$ubol/unzip" "$ubol/unzip-chromium" "$ubol/rules.new"
  unzip -q "$safari" 'rulesets/*' manifest.json js/scripting/css-procedural-api.js -d "$ubol/unzip"
  unzip -q "$chromium" 'rulesets/*' -d "$ubol/unzip-chromium"
  python3 -I "$here/ubol-webkit.py" "$ubol/unzip" "$ubol/rules.new" "$UBOL_VERSION" "$ubol/unzip-chromium"
  rm -rf "$ubol/unzip" "$ubol/unzip-chromium" "$ubol/rules"
  mv "$ubol/rules.new" "$ubol/rules"
  echo "$stamp" > "$ubol/.version"
  find "$ubol" -maxdepth 1 -name 'uBOLite_*.zip' ! -name "uBOLite_$UBOL_VERSION.*" -delete
fi
