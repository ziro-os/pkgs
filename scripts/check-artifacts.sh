#!/bin/sh
# Every artifact hosted by this repo (https://ziro-os.github.io/pkgs/files/<module>/<file>) must
# exist as modules/<module>/<file> with the sha256 its manifest pins.
set -eu
base=https://ziro-os.github.io/pkgs/files/
for m in modules/*/manifest.json; do
	jq -r '.artifacts[]? | "\(.url) \(.sha256)"' "$m" | while read -r url sum; do
		case "$url" in "$base"*) ;; *) continue ;; esac
		f="modules/${url#"$base"}"
		[ -f "$f" ] || { echo "$m: $url: $f is missing" >&2; exit 1; }
		echo "$sum  $f" | sha256sum -c --quiet || { echo "$m: $f: sha256 differs from the manifest" >&2; exit 1; }
	done
done
echo "artifacts OK"
