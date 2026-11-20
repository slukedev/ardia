#!/usr/bin/env bash
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pin="$root/packages/ardiacore/scripts/ubol.sh"
repo="uBlockOrigin/uBOL-home"
current="$(sed -n 's/^UBOL_VERSION="\(.*\)"$/\1/p' "$pin")"
[ -n "$current" ] || { echo "error: no UBOL_VERSION in $pin" >&2; exit 1; }

release="$(curl -fsSL --proto '=https' --retry 3 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$repo/releases/latest")"
read -r latest url digest chromium_url chromium_digest < <(python3 -I -c '
import json, sys
r = json.load(sys.stdin)
if r.get("prerelease") or r.get("draft"):
    sys.exit("error: the latest release is a prerelease or a draft")
out = [r["tag_name"]]
for flavor in ("safari", "chromium"):
    zips = [a for a in r["assets"] if a["name"] == "uBOLite_%s.%s.zip" % (r["tag_name"], flavor)]
    if len(zips) != 1:
        sys.exit("error: the latest release has no single %s zip" % flavor)
    out += [zips[0]["browser_download_url"], (zips[0].get("digest") or "").removeprefix("sha256:") or "-"]
print(*out)
' <<< "$release")
[ -n "$latest" ] || { echo "error: couldn't read the latest uBOL release from GitHub" >&2; exit 1; }

if [ "$latest" = "$current" ]; then
  echo "uBOL $current is the latest release"
  "$pin"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$latest" ]; then
  echo "error: the latest release ($latest) is older than the pinned $current" >&2
  exit 1
fi
if [ "${1:-}" = "--check" ]; then
  echo "uBOL $latest is out (bundled: $current)"
  exit 1
fi
[ "$digest" != "-" ] || { echo "error: GitHub gives no digest for $url; not updating" >&2; exit 1; }
[ "$chromium_digest" != "-" ] || { echo "error: GitHub gives no digest for $chromium_url; not updating" >&2; exit 1; }

ubol="$root/packages/ardiacore/vendor/ubol-webkit"
zip="$ubol/uBOLite_$latest.safari.zip"
mkdir -p "$ubol"
echo "Downloading $url"
curl -fL --proto '=https' --retry 3 -o "$zip.part" "$url"
sha="$(shasum -a 256 "$zip.part" | cut -d' ' -f1)"
[ "$sha" = "$digest" ] || { rm -f "$zip.part"; echo "error: $url has SHA-256 $sha, GitHub says $digest" >&2; exit 1; }
unzip -p "$zip.part" manifest.json | python3 -I -c '
import json, sys
m = json.load(sys.stdin)
want = sys.argv[1]
problems = []
if m.get("version") != want: problems.append("version %r, not %r" % (m.get("version"), want))
if m.get("manifest_version") != 3: problems.append("not MV3")
if not m.get("declarative_net_request", {}).get("rule_resources"): problems.append("no declarativeNetRequest rulesets")
if problems: sys.exit("error: manifest.json: " + "; ".join(problems))
' "$latest"
mv "$zip.part" "$zip"
chromium_zip="$ubol/uBOLite_$latest.chromium.zip"
echo "Downloading $chromium_url"
curl -fL --proto '=https' --retry 3 -o "$chromium_zip.part" "$chromium_url"
chromium_sha="$(shasum -a 256 "$chromium_zip.part" | cut -d' ' -f1)"
[ "$chromium_sha" = "$chromium_digest" ] || { rm -f "$chromium_zip.part"; echo "error: $chromium_url has SHA-256 $chromium_sha, GitHub says $chromium_digest" >&2; exit 1; }
mv "$chromium_zip.part" "$chromium_zip"

old_pin="$(cat "$pin")"
restore_pin() { printf '%s\n' "$old_pin" > "$pin"; echo "error: uBOL $latest didn't convert; the pin stays at $current" >&2; exit 1; }
sed -i '' "s/^UBOL_VERSION=\".*\"$/UBOL_VERSION=\"$latest\"/; s/^UBOL_SHA256=\".*\"$/UBOL_SHA256=\"$sha\"/; s/^UBOL_CHROMIUM_SHA256=\".*\"$/UBOL_CHROMIUM_SHA256=\"$chromium_sha\"/" "$pin"
"$pin" || restore_pin
[ "$(cut -d- -f1 "$ubol/.version")" = "$latest" ] || restore_pin
echo "uBOL $current -> $latest (sha256 $sha)"
echo "Commit it: git add packages/ardiacore/scripts/ubol.sh && git commit -m \"WebKit content blocker: uBlock Origin Lite $latest\""
