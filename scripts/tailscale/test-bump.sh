#!/bin/bash
# Offline test of scripts/bump-tailscale.sh. A fake pkgs.tailscale.com (curl and gh stand-ins on PATH) serves
# tarballs holding real static Go binaries for amd64 and arm64, and each case damages one thing the script is
# meant to refuse. Needs go, jq, tar and readelf; touches nothing outside a temp directory.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ver=1.90.1

# --- fake upstream ---------------------------------------------------------------------------------------------
mkdir -p "$t/src" "$t/shim" "$t/tgz"
cat >"$t/src/main.go" <<'EOF'
package main

import "fmt"

var version, kind = "dev", "x"

func main() { fmt.Println(version); fmt.Println("  go version: fake " + kind) }
EOF
printf 'module fake\n\ngo 1.21\n' >"$t/src/go.mod"

build() { # <version> <goarch> <bin> <dest>
	(cd "$t/src" && CGO_ENABLED=0 GOOS=linux GOARCH=$2 go build -ldflags "-X main.version=$1 -X main.kind=$3" -o "$4" .)
}
pack() { # <version> <goarch>: tar the directory and publish its checksum next to it
	(cd "$t/tgz" && tar -czf "tailscale_${1}_$2.tgz" "tailscale_${1}_$2" &&
		sha256sum "tailscale_${1}_$2.tgz" | awk -v n="tailscale_${1}_$2.tgz" '{print $1 "  " n}' >"tailscale_${1}_$2.tgz.sha256")
}
for a in amd64 arm64; do
	mkdir -p "$t/tgz/tailscale_${ver}_$a/systemd"
	for b in tailscale tailscaled; do build "$ver" "$a" "$b" "$t/tgz/tailscale_${ver}_$a/$b"; done
	pack "$ver" "$a"
done
cp -r "$t/tgz" "$t/tgz.good"

cat >"$t/shim/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out=$2; shift 2 ;;
	--retry|--max-time) shift 2 ;;
	-*) shift ;;
	*) url=$1; shift ;;
	esac
done
case "$url" in
https://pkgs.tailscale.com/stable/\?mode=json) src=$FAKE_DIR/index.json ;;
https://pkgs.tailscale.com/stable/*) src=$FAKE_DIR/tgz/${url##*/} ;;
*) echo "unexpected url $url" >&2; exit 22 ;;
esac
[ -f "$src" ] || { echo "404 $url" >&2; exit 22; }
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
EOF
cat >"$t/shim/gh" <<'EOF'
#!/bin/sh
case "$*" in
*"git/ref/tags/v"*) v=${*##*tags/v}; case " $FAKE_TAGS " in *" $v "*) echo '{}'; exit 0 ;; esac ;;
esac
exit 1
EOF
chmod +x "$t/shim/curl" "$t/shim/gh"

# --- harness ---------------------------------------------------------------------------------------------------
fails=0
index() { printf '{"TarballsVersion":"%s","Tarballs":{"amd64":"tailscale_%s_amd64.tgz","arm64":"tailscale_%s_arm64.tgz"}}' "$1" "$1" "$1" >"$t/index.json"; }
fresh() { rm -rf "$t/tgz" && cp -r "$t/tgz.good" "$t/tgz"; index "$ver"; tags=$ver; }

run() { # <name> <expected rc> <expected message or ''>  — runs the script in a scratch copy of the repo
	name=$1 want=$2 msg=$3
	w=$t/work-$(echo "$name" | tr -c 'a-z0-9\n' _)
	mkdir -p "$w/scripts/tailscale" "$w/modules/tailscale"
	cp "$repo/scripts/bump-tailscale.sh" "$w/scripts/"
	cp "$repo/scripts/tailscale/manifest.template.json" "$w/scripts/tailscale/"
	[ -n "${pinned:-}" ] && printf '{"version":"%s"}\n' "$pinned" >"$w/modules/tailscale/manifest.json"
	rc=0
	out=$(cd "$w" && FAKE_DIR=$t FAKE_TAGS=$tags PATH=$t/shim:$PATH sh scripts/bump-tailscale.sh "$w/out" 2>&1) || rc=$?
	if [ "$rc" = "$want" ] && { [ -z "$msg" ] || printf '%s' "$out" | grep -q "$msg"; }; then
		echo "ok   $name"
	else
		echo "FAIL $name (rc=$rc, want $want, want message '$msg')"
		printf '%s\n' "$out" | sed 's/^/     /'
		fails=$((fails + 1))
	fi
	last=$w
	unset pinned
}

fresh; run "pins a stable release" 0 "^$ver\$"
m=$last/modules/tailscale/manifest.json
# every manifest entry pins the hash and URL of the file with its own name (tailscale and tailscaled differ)
for pair in x86_64:amd64 aarch64:arm64; do
	for b in tailscaled tailscale; do
		arch=${pair%%:*} g=${pair#*:}
		got=$(jq -r --arg arch "$arch" --arg b "$b" '.artifacts[] | select(.arch == $arch and (.path | endswith("/" + $b))) | "\(.sha256) \(.url)"' "$m")
		want="$(sha256sum "$last/out/$b-linux-$g" | cut -d' ' -f1) https://github.com/ziro-os/pkgs/releases/download/tailscale-$ver/$b-linux-$g"
		if [ "$got" = "$want" ]; then echo "ok   manifest pins $arch $b"; else echo "FAIL manifest pins $arch $b: $got"; fails=$((fails + 1)); fi
	done
done
[ "$(sha256sum "$last/out/tailscale-linux-amd64" "$last/out/tailscaled-linux-amd64" | cut -d' ' -f1 | sort -u | wc -l)" = 2 ] ||
	{ echo "FAIL the two amd64 binaries should differ"; fails=$((fails + 1)); }

fresh; pinned=$ver run "nothing to do when current" 0 ""
[ ! -s "$last/out/tailscaled-linux-amd64" ] || { echo "FAIL staged binaries although current"; fails=$((fails + 1)); }
fresh; pinned=1.92.0 run "refuses to go back" 1 "refusing to go back"
fresh; pinned=1.88.2 run "upgrades from an older pin" 0 "^$ver\$"
fresh; index 1.91.0; tags=1.91.0; run "refuses an unstable (odd minor) release" 1 "unstable"
fresh; tags=""; run "refuses a version with no upstream tag" 1 "not a tag"
fresh; echo "deadbeef  x" >"$t/tgz/tailscale_${ver}_amd64.tgz.sha256"; run "refuses a checksum mismatch" 1 "Tailscale publishes"
fresh; rm "$t/tgz/tailscale_${ver}_arm64.tgz.sha256"; run "refuses a missing checksum" 1 ""
fresh; cp /bin/true "$t/tgz/tailscale_${ver}_amd64/tailscaled"; pack "$ver" amd64; run "refuses a dynamically linked binary" 1 "dynamically linked"
fresh; cp "$t/tgz/tailscale_${ver}_amd64/tailscaled" "$t/tgz/tailscale_${ver}_arm64/tailscaled"; pack "$ver" arm64; run "refuses the wrong architecture" 1 "is not aarch64"
fresh; build 1.90.2 amd64 tailscaled "$t/tgz/tailscale_${ver}_amd64/tailscaled"; pack "$ver" amd64; run "refuses a binary that reports another version" 1 "does not report"
fresh; (cd "$t/tgz" && tar -czf "tailscale_${ver}_amd64.tgz" --transform "s,^tailscale_${ver}_amd64/,../evil/," "tailscale_${ver}_amd64" &&
	sha256sum "tailscale_${ver}_amd64.tgz" | awk -v n="tailscale_${ver}_amd64.tgz" '{print $1 "  " n}' >"tailscale_${ver}_amd64.tgz.sha256")
run "refuses an archive with parent-relative paths" 1 "parent-relative"

[ "$fails" = 0 ] && echo "bump-tailscale: all cases passed" || { echo "bump-tailscale: $fails failed"; exit 1; }
