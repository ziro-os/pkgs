# Contributing a plugin

A plugin runs as root on every host that enables it, so review is strict. Open a pull request that adds
`modules/<name>/manifest.json` (and any helper files next to it). CI runs `ziroctl plugin validate` and checks
hosted artifacts; a maintainer reviews against the rules below.

## Rules

1. **Declarative only.** Commands are an absolute path plus an argument list. No `sh -c`, no shell strings.
   A helper script is an artifact: small, `set -eu`, idempotent (post-start steps run at every boot).
2. **Pin everything.** Packages come from the pinned Alpine release. Anything else is an `artifact` with an https
   URL and its sha256. Files hosted here go in `modules/<name>/` and are served from
   `https://ziro-os.github.io/pkgs/files/<name>/<file>`.
3. **Least privilege.** Daemons run as their own `user`, not root. Config files that hold secrets are `0600`, or
   `0640` with `owner: root:<daemon-group>`.
4. **Secrets are generated, never shipped.** Use `secrets` (`hex:N`, `base64:N`, `alnum:N`) and `{{secret.x}}` in
   files. Secrets can't go on command lines or in cron lines (validation refuses it).
5. **Safe settings.** Every `setting` has an anchored `pattern` (`^...$`) as narrow as the value allows.
6. **Loopback by default.** Don't listen on public addresses unless the plugin exists for that; expose it through
   a setting, and the host firewall still applies.
7. **Reversible.** `disable` must leave the host as it was, except data directories. Test enable, re-enable,
   upgrade from the previous version, and disable on a real host.
8. **Versioning.** Semantic versions. Bump `version` for every change; hosts upgrade with `ziroctl plugin upgrade`.

## Checklist for the pull request

- [ ] `ziroctl plugin validate modules/<name>/manifest.json`
- [ ] `ziroctl plugin install -f modules/<name>/manifest.json` on a Ziro OS host (x86_64 and/or arm64), then
      `plugin info`, the health check, a reboot, and `plugin disable`
- [ ] The description says what it listens on and which user it runs as
