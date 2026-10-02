# drml

`drml` is a Zig package manager for JavaScript and TypeScript projects. The project is being built in small, compatible slices.

## Current milestone

The current milestone is the **exact-version installer**:

- `drml install` reads `package.json`.
- `drml check` scans JavaScript and TypeScript source for package imports that are missing from `package.json`.
- It understands `dependencies`, `devDependencies`, `optionalDependencies`, `peerDependencies`, and `peerDependenciesMeta` as manifest data.
- It validates exact-version dependency entries for a small initial slice and writes `drml-lock.json`.
- Normal `drml install` queries the npm registry, validates that each exact version exists, downloads the package tarball, records npm integrity metadata, and extracts direct packages into `node_modules`.
- Downloaded archives are cached in `.drml-cache/`; package tarballs are unpacked with path components stripped from npm's `package/` archive root.
- `devDependencies` are installed as well as recorded with `"dev": true`.
- `drml install --lockfile-only` preserves the previous manifest/lockfile-only behavior for offline generation and fixture tests.
- The installer currently installs direct dependencies only. Transitive dependency solving, executable shims in `node_modules/.bin`, lifecycle scripts, range resolution, and lockfile reuse are still future work.
- It keeps the implementation free of third-party Zig packages.

The resolver intentionally fails rather than silently guessing for unsupported ranges or dependency protocols. That behavior will make later compatibility work explicit.

## Build

```sh
zig build
zig build test
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe
zig build run -- --help
```

WASI compilation is a required build target, not an optional experiment. The current CLI uses WASI filesystem and argument APIs; browser-only WebAssembly without WASI will require a separate host adapter later.


## Source layout

The code is intentionally split by responsibility so drml can grow beyond the package manager:

```text
src/
├── main.zig               # CLI parsing and command dispatch
└── package_manager.zig    # manifest parsing, validation, and lockfile generation
```

Planned modules will follow the same boundary: `package_checker.zig`, `scaffolder.zig`, `compiler.zig`, `test_runner.zig`, and `dev_server.zig`. They should depend on shared manifest, resolver, store, and process abstractions rather than putting all behavior back into `main.zig`.

The package checker is implemented in `src/package_checker.zig`. It currently recognizes static ESM imports, re-exports, CommonJS `require`, and literal dynamic `import()` calls. It normalizes scoped package subpaths, ignores relative imports and Node built-ins, skips comments and strings, and does not scan `node_modules`, build output, or coverage directories. Dynamic imports whose specifier is not a literal are intentionally skipped until a richer parser/AST layer is added.

The checker also skips regular-expression literals and supports multiline imports plus comments between import syntax tokens.

## Planned milestones

1. Transitive dependency resolution, executable shims, lockfile reuse, and stronger integrity verification.
2. Complete semver range solving, offline/frozen modes, and content-addressed storage.
3. pnpm-style content-addressed store and isolated `node_modules` linker.
4. Workspaces, peer-dependency solving, optional/platform dependencies, and lifecycle policy.
5. Package checker, scaffolder, compiler, test runner, and dev server.

## Fixture testing

The repository includes a fixture matrix for ordinary manifests and failure behavior:

```sh
zig build test
zig build
./tests/run-fixtures.sh
```

The fixtures cover dependency-field combinations, scoped names, package-manager metadata, invalid manifest shapes, exact-version failures, workspace protocols, monorepo roots, nested workspace packages, all supported foreign lockfile names, and missing manifests. Registry-existence fixtures run when `DRML_LIVE_TESTS=1`.

The audit regression fixtures additionally cover non-object manifests, escaped lockfile strings, duplicate dependencies, scoped tarball URLs, leading-zero versions, extra CLI arguments, regex literals, multiline imports, and comments between import tokens.

The network-backed smoke test can be run explicitly when npm registry access is available:

```sh
./tests/run-live-install.sh
```

## CI and releases

GitHub Actions runs formatting checks, Zig unit tests, the fixture matrix, and a release-safe build on pushes to `main` and pull requests.

Publishing a GitHub Release triggers `.github/workflows/release.yml`. It cross-compiles and attaches ZIP archives for:

- Linux x86_64 and aarch64
- macOS x86_64 and aarch64
- Windows x86_64
- WASI `wasm32-wasi`

To create the same kind of local archive:

```sh
DRML_VERSION=0.1.0 DRML_ARCHIVE=linux-x86_64 ./scripts/package-release.sh
```
