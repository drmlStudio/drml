# drml research notes

## Scope

This first milestone deliberately focuses on the package-manager core: reading a root `package.json`, resolving registry packages, writing a deterministic lockfile, and materializing dependencies. Compiler, test runner, package checker, scaffolder, and dev server remain later milestones.

## Findings

- npm treats `dependencies` as runtime requirements and `devDependencies` as development-only requirements. npm v7+ installs `peerDependencies` by default and uses `peerDependenciesMeta` to mark peers optional. npm also supports registry ranges, tarballs, git URLs, local paths, aliases, and tags. [1]
- npm's lockfile is a committed representation of the exact dependency tree. Modern lockfiles record package locations, resolved URLs, integrity hashes, dependency metadata, and whether packages are dev/optional/bundled. [2]
- npm's install tree can hoist packages, which is convenient but permits undeclared or "phantom" imports to work accidentally. npm documents isolated/linked layouts as a way to catch those imports. [3]
- pnpm separates resolution, fetching, directory-layout calculation, and linking. It stores package files in a content-addressable store and links them into projects, reducing duplicate disk usage. [4]
- pnpm's frozen-lockfile mode fails if the manifest and lockfile disagree; offline mode must fail when a required artifact is absent. Integrity mismatches are hard failures by default. [5]
- Yarn Plug'n'Play enforces declared dependency access and emits semantic errors for undeclared dependencies. drml should eventually expose the same package-checking guarantees even if its initial linker is `node_modules`. [6]
- Bun confirms a useful compatibility target: npm-style manifests, committed lockfiles, frozen installs, offline installs, platform-specific optional dependencies, and workspaces. [7] [8]
- npm provenance is a publishing/CI attestation feature, not an install-time package-resolution feature. drml should reserve a future `publish --provenance` path and not pretend that a local install can create provenance. [9]

## Initial design decisions

1. **Manifest compatibility first:** read the standard dependency sections and preserve npm package names and semver range strings.
2. **Deterministic lockfile:** use a drml-owned lockfile initially, recording exact version, tarball URL, integrity, and dependency sections. Add npm lockfile import/export after the resolver is stable.
3. **Content-addressed cache:** cache downloaded tarballs by integrity digest, with a configurable cache root under `$XDG_CACHE_HOME/drml` or `~/.cache/drml`.
4. **No third-party Zig packages:** keep the implementation in the Zig standard library. The first prototype may use the host `curl` and `tar` executables behind a small process adapter while native HTTP/archive support is added.
5. **Safe defaults:** frozen installs, scripts, registries, workspaces, peer solving, platform filters, and lifecycle builds are separate milestones rather than hidden partial behavior.

## Sources

[1]: https://docs.npmjs.com/cli/v12/configuring-npm/package-json/ "npm package.json"
[2]: https://docs.npmjs.com/cli/v8/configuring-npm/package-lock-json/ "npm package-lock.json"
[3]: https://docs.npmjs.com/cli/v12/commands/npm-install/ "npm install"
[4]: https://pnpm.io/motivation "pnpm motivation"
[5]: https://pnpm.io/cli/install "pnpm install"
[6]: https://yarnpkg.com/features/pnp "Yarn Plug'n'Play"
[7]: https://bun.com/docs/pm/cli/install "Bun install"
[8]: https://bun.com/docs/pm/lockfile "Bun lockfile"
[9]: https://docs.npmjs.com/generating-provenance-statements/ "npm provenance statements"

## Fixture policy

The repository keeps small fixtures for both supported behavior and deliberate refusal behavior. The runner treats refusal as a regression if the diagnostic changes unexpectedly. The `nonexistent-package` and `nonexistent-version` fixtures currently remain known gaps because the lockfile-only prototype does not query registry metadata; they must become hard failures when registry resolution lands.

Foreign lockfiles are detected before drml writes its own lockfile. This prevents silently mixing npm, pnpm, Yarn, or Bun state with drml state. The next compatibility milestone should add import adapters that normalize each format into a common internal graph, preserve integrity/resolved data, and reject ambiguous or incomplete imports.
