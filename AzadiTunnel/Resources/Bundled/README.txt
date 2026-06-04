Bundled Psiphon resources (Shiro Khorshid pattern)

Default files are generated from the public Shiro Khorshid Android release APK
(see Tooling/psiphon/extract-shiro-bundled-from-apk.sh). Upstream git repos only
ship .stub templates — not live sponsor/propagation values.

Optional gitignored overrides (take precedence over defaults):

  psiphon-config.local.json
  psiphon-embedded-server-entries.local.txt

See docs/BUNDLED_PSIPHON_CONFIG.md in the repo root.
