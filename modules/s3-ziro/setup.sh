#!/bin/sh
# s3-ziro post-start: single-node Garage layout, the ziro-backups bucket and its access key.
# Idempotent: it runs after every enable, upgrade and boot. Usage: setup.sh <capacity>
set -eu
CFG=/etc/garage/garage.toml
ENV=/etc/ziro/rclone.d/ziro-s3.env
CAP="${1:?capacity}"
g() { /usr/bin/garage -c "$CFG" "$@"; }
val() { sed -n "s/^$1=//p" "$ENV"; }
KEY_ID=$(val RCLONE_CONFIG_ZIRO_S3_ACCESS_KEY_ID)
KEY_SECRET=$(val RCLONE_CONFIG_ZIRO_S3_SECRET_ACCESS_KEY)

i=0
until g status >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -ge 60 ] && { echo "garage is not answering" >&2; exit 1; }
	sleep 1
done

if g layout show | grep -q "No nodes currently have a role"; then
	node=$(g node id -q | cut -d@ -f1)
	g layout assign -z dc1 -c "$CAP" "$node"
	g layout apply --version 1
fi
g key info "$KEY_ID" >/dev/null 2>&1 || g key import --yes -n ziro-backups "$KEY_ID" "$KEY_SECRET" >/dev/null
g bucket info ziro-backups >/dev/null 2>&1 || g bucket create ziro-backups >/dev/null
g bucket allow --read --write --owner ziro-backups --key "$KEY_ID" >/dev/null
echo "s3-ziro ready: bucket ziro-backups, endpoint http://$(sed -n 's/^api_bind_addr = "\(.*\)"/\1/p' "$CFG" | head -1)"
