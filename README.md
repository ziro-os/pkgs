# Ziro OS plugins

The official plugin catalog for [Ziro OS](https://github.com/ziro-os/ziro-os). Every `ziroctl` trusts it out of
the box: CI validates each manifest, signs the index with the key whose public half is compiled into `ziroctl`
(`catalog.pub`), and publishes it to <https://ziro-os.github.io/pkgs>.

```sh
ziroctl plugin search
ziroctl plugin info s3-ziro
ziroctl plugin enable s3-ziro --set capacity=50G
ziroctl plugin enable rclone-ziro
ziroctl backup create --remote ziro_s3:ziro-backups
```

| Plugin | What it does |
|---|---|
| [`s3-ziro`](modules/s3-ziro/manifest.json) | S3-compatible object storage ([Garage](https://garagehq.deuxfleurs.fr)) for backups, snapshots and apps. Runs as `garage`; S3 API on `127.0.0.1:3900` unless `--set bind=0.0.0.0`; creates the `ziro-backups` bucket and the `ziro_s3` rclone remote. |
| [`cloudflared`](modules/cloudflared/manifest.json) | Cloudflare Tunnel: publish services without a public IP, optional Zero Trust Access; managed with `ziroctl cf`. Runs as `cloudflared`. A [daily job](.github/workflows/cloudflared-bump.yml) pins each new upstream release after checking its sha256 against GitHub's digest and Cloudflare's release notes. |
| [`tailscale`](scripts/tailscale/manifest.template.json) | Reach the host over your [tailnet](https://tailscale.com); managed with `ziroctl tailscale`. Runs as `tailscale` with only `CAP_NET_ADMIN` and `CAP_NET_RAW`; nothing is open to the tailnet until you `ziroctl tailscale allow`. A [daily job](.github/workflows/tailscale-bump.yml) pins the newest stable release after [verifying it](scripts/bump-tailscale.sh); the manifest appears in `modules/tailscale/` once the job has run. |
| [`rclone-ziro`](modules/rclone-ziro/manifest.json) | rclone for S3, GCS, Azure Blob, B2, SFTP and more; enables `ziroctl backup --remote`. |

Built-in modules (ClamAV, auditd, NFS, the security pack) ship inside `ziroctl` itself.

### How Tailscale is delivered

Upstream ships one tarball holding both daemons, and the module framework can't unpack archives. So the bump job
checks the tarballs (stable series, a real upstream tag, Tailscale's published sha256, static binaries of the
right architecture, the amd64 pair run and report the version), publishes the four single binaries as assets of a
`tailscale-<version>` release of this repository, and pins each one's sha256 in `modules/tailscale/manifest.json`.
The signed catalog carries that manifest, so a host verifies the signature, the manifest hash and every binary's
hash, at install and again at every boot. The newest five releases are kept. `scripts/tailscale/test-bump.sh`
exercises the checks offline (a tampered checksum, an unstable release, a dynamic binary, the wrong architecture,
a path-traversal archive, a downgrade) and runs on every pull request.

## WAF rules

[`waf/zirogate-crs`](waf/zirogate-crs/rules.json) is the rule set of the Ziro OS gateway's web application firewall.
It is published as a second signed catalog at <https://ziro-os.github.io/pkgs/waf>, with the same key. A new rule
reaches every gateway without a `ziroctl` release:

```sh
ziroctl gateway waf update            # fetch, verify and install the newest rules now
ziroctl gateway waf status            # the rules in use, staged rules, rollback
ziroctl gateway waf rollback          # return to the previous rules
```

Hosts also check about once a day (`ziroctl gateway settings set --waf-auto-update=false` stops that), and on a
cluster master `waf update` makes every gateway node fetch the rules at once. Running gateways switch to new rules
within a second, without a restart. A host that is offline keeps the rules it has, and a host that has never fetched
a pack uses the rules built into `ziroctl`. See the [gateway guide](https://github.com/ziro-os/ziro-os/blob/main/docs/gateway.md#updating-the-rules).

The rules are plain JSON that every host validates before use: sizes are capped, expressions are RE2 (linear time),
and each rule carries samples it must and must not match. A pack that fails any check is not installed.
[CONTRIBUTING.md](CONTRIBUTING.md#contributing-a-waf-rule) explains how to add a rule.

## Writing a plugin

```sh
ziroctl plugin new hello                       # scaffold hello/manifest.json
ziroctl plugin validate hello/manifest.json
ziroctl plugin install -f hello/manifest.json  # try it on a host (unsigned; development only)
```

[`examples/hello-plugin`](examples/hello-plugin/manifest.json) is a complete small plugin. The manifest reference,
lifecycle and trust model are in the [modules guide](https://github.com/ziro-os/ziro-os/blob/main/docs/modules.md).
See [CONTRIBUTING.md](CONTRIBUTING.md) to publish here, or run your own catalog with `ziroctl catalog build|sign`
(this repo's [workflow](.github/workflows/catalog.yml) is a working example).

## License

MIT. Each plugin installs software under that software's own license.
