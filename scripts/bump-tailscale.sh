#!/bin/sh
# Pin the newest stable Tailscale release in modules/tailscale/manifest.json.
#
# Usage: scripts/bump-tailscale.sh <out-dir>
#
# Upstream ships a .tgz holding both daemons, and the module framework cannot unpack archives, so the four
# single binaries (tailscaled and tailscale, x86_64 and aarch64) are staged in <out-dir> for the workflow to
# publish as release assets of this repository; the manifest pins each one's sha256 and the signed catalog
# carries the manifest. Nothing here trusts a single source:
#   - the version comes from Tailscale's release index and must be a stable (even minor) release whose tag also
#     exists in github.com/tailscale/tailscale, and never lower than the version already pinned
#   - each tarball's sha256 must match the checksum Tailscale publishes next to it
#   - the archive may not contain absolute or parent-relative paths
#   - the binaries must be static (the host is musl), of the right architecture, and the x86_64 pair must run
#     and report exactly this version
# Any failure exits non-zero before the manifest is touched. Prints the new version; prints nothing when the
# pinned version is already current.
set -eu

out=${1:?usage: bump-tailscale.sh <out-dir>}
m=modules/tailscale/manifest.json
tpl=scripts/tailscale/manifest.template.json
base=https://pkgs.tailscale.com/stable
rel_url=https://github.com/ziro-os/pkgs/releases/download

idx=$(curl -fsSL --retry 3 --max-time 60 "$base/?mode=json")
ver=$(printf '%s' "$idx" | jq -r .TarballsVersion)
# 1.<even minor>.<patch> is Tailscale's stable series; odd minors are unstable.
printf '%s' "$ver" | grep -Eq '^1\.[0-9]*[02468]\.[0-9]+$' || { echo "unexpected or unstable version '$ver'" >&2; exit 1; }
gh api "repos/tailscale/tailscale/git/ref/tags/v$ver" >/dev/null ||
	{ echo "v$ver is not a tag of tailscale/tailscale" >&2; exit 1; }

if [ -f "$m" ]; then
	cur=$(jq -r .version "$m")
	[ "$cur" = "$ver" ] && exit 0
	[ "$(printf '%s\n%s\n' "$cur" "$ver" | sort -V | tail -n1)" = "$ver" ] ||
		{ echo "refusing to go back from $cur to $ver" >&2; exit 1; }
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
new=$(jq --arg v "$ver" '.version = $v' "$tpl")

for pair in amd64:x86_64:"X86-64" arm64:aarch64:"AArch64"; do
	a=${pair%%:*}
	rest=${pair#*:}
	arch=${rest%%:*}
	machine=${rest#*:}

	name=$(printf '%s' "$idx" | jq -r --arg a "$a" '.Tarballs[$a] // empty')
	[ "$name" = "tailscale_${ver}_$a.tgz" ] || { echo "index lists '$name' for $a, expected tailscale_${ver}_$a.tgz" >&2; exit 1; }
	curl -fsSL --retry 3 --max-time 300 -o "$tmp/$name" "$base/$name"
	want=$(curl -fsSL --retry 3 --max-time 60 "$base/$name.sha256" | awk '{print $1; exit}')
	got=$(sha256sum "$tmp/$name" | cut -d' ' -f1)
	[ -n "$want" ] && [ "$got" = "$want" ] || { echo "$name: downloaded $got, Tailscale publishes '$want'" >&2; exit 1; }

	if tar -tzf "$tmp/$name" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
		echo "$name: archive has absolute or parent-relative paths" >&2
		exit 1
	fi
	mkdir "$tmp/$a"
	tar -xzf "$tmp/$name" -C "$tmp/$a"

	for bin in tailscaled tailscale; do
		f=$(find "$tmp/$a" -type f -name "$bin")
		[ -n "$f" ] && [ "$(printf '%s\n' "$f" | wc -l)" -eq 1 ] || { echo "$name: expected exactly one $bin" >&2; exit 1; }
		readelf -h "$f" | grep -q "Machine:.*$machine" || { echo "$name: $bin is not $arch" >&2; exit 1; }
		if readelf -lW "$f" | grep -q INTERP; then
			echo "$name: $bin is dynamically linked, the host is musl" >&2
			exit 1
		fi
		dest=$out/$bin-linux-$a
		install -m 0755 "$f" "$dest"
		sum=$(sha256sum "$dest" | cut -d' ' -f1)
		new=$(printf '%s' "$new" | jq --arg arch "$arch" --arg bin "$bin" --arg url "$rel_url/tailscale-$ver/$bin-linux-$a" --arg sum "$sum" \
			'(.artifacts[] | select(.arch == $arch and (.path | endswith("/" + $bin)))) |= (.url = $url | .sha256 = $sum)')
	done
done

# The x86_64 binaries must run here and report exactly the pinned version.
[ "$("$out/tailscaled-linux-amd64" --version | head -n1)" = "$ver" ] || { echo "tailscaled does not report $ver" >&2; exit 1; }
[ "$("$out/tailscale-linux-amd64" version | head -n1)" = "$ver" ] || { echo "tailscale does not report $ver" >&2; exit 1; }

# Every artifact must have been rewritten from the template's placeholder.
printf '%s' "$new" | jq -e '[.artifacts[] | select(.sha256 | test("^0+$"))] | length == 0' >/dev/null ||
	{ echo "an artifact kept the placeholder hash" >&2; exit 1; }

mkdir -p "$(dirname "$m")"
printf '%s\n' "$new" >"$m"
echo "$ver"
