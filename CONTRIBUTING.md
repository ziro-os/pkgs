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

## Contributing a WAF rule

The rules in [`waf/zirogate-crs/rules.json`](waf/zirogate-crs/rules.json) run on every Ziro OS gateway that has the
WAF on, so a rule that blocks legitimate traffic is an outage for someone. Open a pull request that edits the file
and, where the rule needs it, `benign.txt`. CI runs `ziroctl gateway waf test` on both; a maintainer reviews against
the rules below.

### Rules

1. **Stable IDs.** A rule is `ZW-` and six digits: the first three name the group (`942` SQL injection, `941` XSS,
   `930` file inclusion, `932` command and code injection, `944` Java, `946` XML, `934` SSRF, `913` scanners). Never
   reuse an ID or change what an ID means; refine the rule, or retire it by moving the ID to `retired`.
2. **Two samples at least.** Every rule carries `tests.match` (text it must fire on) and `tests.nomatch` (similar
   text it must not). Samples run through the same normalizer as request data: lower-case, percent-decoded,
   comments collapsed. Write expressions in lower case.
3. **Needles.** `needles` are lower-case literals, one of which must occur before the expression runs. They are what
   keeps the WAF fast, so choose literals that rarely appear in clean traffic and cover every way the expression can
   match.
4. **RE2 only.** No look-around or back-references. Keep the expression under 2 KiB and anchor it as tightly as
   the attack allows.
5. **Score by confidence.** 5 blocks alone, 4 blocks with one more signal, 3 and 2 only add up. Use `level` 1 for rules
   with almost no false positives, 2 for broader ones, 3 for paranoid ones.
6. **Stage risky rules.** `"stage": "detect"` logs and counts matches without adding to the score. Ship a new rule
   there when it could match legitimate traffic, watch `zirogate_waf_matches_total`, and remove the stage when it is
   quiet. `"stage": "off"` disables a rule without retiring it.
7. **Cite the advisory.** Put CVE or advisory identifiers in `refs`.
8. **No secrets and no customer data** in a rule, a sample or `benign.txt`.
9. **Record false positives.** When a rule blocks a legitimate request, add that request to `benign.txt` together
   with the fix.

### Checklist for the pull request

- [ ] `ziroctl gateway waf test waf/zirogate-crs/rules.json --benign waf/zirogate-crs/benign.txt`
- [ ] The pack's `version` is bumped (`YYYY.M.N`)
- [ ] The description says what the rule catches, how it was tested, and whether it ships at the `detect` stage

Once merged, the catalog is signed and published within minutes. `ziroctl gateway waf update` installs it at once and
hosts that update automatically pick it up within a day.
