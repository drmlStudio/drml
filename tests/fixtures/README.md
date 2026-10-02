# drml fixture corpus

Each directory is a deliberately small compatibility or failure fixture. The runner copies a fixture to a temporary directory so generated lockfiles never pollute the repository.

## Passing fixtures

- `minimal-exact`: one exact registry version.
- `all-dependency-types`: all supported dependency sections plus `packageManager` metadata.
- `package-manager-{npm,pnpm,yarn,bun}`: supported package-manager metadata values are preserved.
- `scoped-package`: scoped package naming and tarball URL formatting.

## Expected failures

- `range-version`: semver ranges are reserved for the resolver milestone.
- `workspace-protocol`: local workspace protocol is reserved for monorepo resolution.
- `git-dependency`: non-registry protocols are explicit errors.
- `invalid-*`: malformed manifest shapes are rejected.
- `monorepo-root`, `nested-package`: workspaces are detected and refused instead of silently ignored.
- `foreign-*`: npm, npm-shrinkwrap, pnpm, Yarn, and Bun lockfiles are detected and refused until import adapters exist.
- `nonexistent-*`: fixtures reserved for registry metadata resolution; the current lockfile-only milestone cannot yet prove registry existence.

Run the complete matrix with:

```sh
zig build
./tests/run-fixtures.sh
```
