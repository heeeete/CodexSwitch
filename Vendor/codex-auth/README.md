# Vendored codex-auth

CodexSwitch bundles exact upstream `codex-auth` binaries, so end users do not
install npm, Node.js, or `codex-auth` separately.

- Version: `0.2.10` (stable)
- Source commit: `0642f6fa16df2941afe42f8ee5f9ead2d8595a9e`
- Source archive SHA-256: `ec66175d5b42f40403dbe0f5a5f4ca3f6bea3885d11f9ed36f0a6f4bcba73a9f`
- Source: `source/`
- Official npm macOS binaries: `bin/`
- Binary hashes: `SHA256SUMS`
- Original GitHub/npm archives: `upstream/`
- Registry integrity and archive provenance: `NPM_PROVENANCE.json`, `UPSTREAM_SHA256SUMS`

The source archive came from the upstream GitHub commit. The platform binaries
came from the official npm packages for the same commit and version. Release
builds accept only these vendored files, verify the original archive hashes,
and confirm that the bundled executable is byte-identical to the npm archive
before copying it into the app bundle.

CodexSwitch intentionally keeps the stable schema-3 release. The UI performs
account switching by exact `account_key`; it does not use the CLI's display-row
selector. This avoids both ambiguous selection and prerelease registry
migrations.
