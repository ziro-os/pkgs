#!/bin/sh
# Pin the latest cloudflared release in modules/cloudflared/manifest.json. Each binary's sha256 must
# match both GitHub's asset digest and the list in Cloudflare's release notes, and the amd64 binary
# must run and report the tag. Prints the new version; prints nothing when already current.
set -eu
m=modules/cloudflared/manifest.json
rel=$(gh api repos/cloudflare/cloudflared/releases/latest)
tag=$(printf '%s' "$rel" | jq -r .tag_name)
case "$tag" in
20[0-9][0-9].[0-9]*.[0-9]*) ;;
*) echo "unexpected tag $tag" >&2; exit 1 ;;
esac
[ "$(jq -r .version "$m")" = "$tag" ] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
new=$(cat "$m")
for pair in amd64:x86_64 arm64:aarch64; do
	a=${pair%%:*}
	arch=${pair#*:}
	name=cloudflared-linux-$a
	url=https://github.com/cloudflare/cloudflared/releases/download/$tag/$name
	digest=$(printf '%s' "$rel" | jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest' | sed 's/^sha256://')
	notes=$(printf '%s' "$rel" | jq -r .body | tr -d '\r' | sed -n "s/^$name: *\([0-9a-f]\{64\}\)\$/\1/p")
	curl -fsSL --retry 3 -o "$tmp/$name" "$url"
	sum=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
	if [ -z "$digest" ] || [ "$sum" != "$digest" ] || [ "$sum" != "$notes" ]; then
		echo "$name: downloaded $sum, GitHub digest $digest, release notes $notes" >&2
		exit 1
	fi
	new=$(printf '%s' "$new" | jq --arg arch "$arch" --arg url "$url" --arg sum "$sum" \
		'(.artifacts[] | select(.arch == $arch)) |= (.url = $url | .sha256 = $sum)')
done
chmod +x "$tmp/cloudflared-linux-amd64"
"$tmp/cloudflared-linux-amd64" --version | grep -q "cloudflared version $tag "
printf '%s\n' "$new" | jq --arg v "$tag" '.version = $v' >"$m"
echo "$tag"
