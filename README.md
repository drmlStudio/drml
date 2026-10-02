![Logo](./assets/logo-drml-black.svg)

# drml

[![CI](https://img.shields.io/github/actions/workflow/status/drmlStudio/drml/ci.yml?branch=main&label=CI)](https://github.com/drmlStudio/drml/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/drmlStudio/drml?display_name=tag)](https://github.com/drmlStudio/drml/releases)
[![License](https://img.shields.io/github/license/drmlStudio/drml)](LICENSE)
[![Built with Zig](https://img.shields.io/badge/built%20with-Zig-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Docs](https://img.shields.io/badge/docs-VitePress-646CFF?logo=vitepress&logoColor=white)](https://github.com/drmlStudio/drml/tree/main/website)

`drml` is an explicit package manager for JavaScript and TypeScript projects, built in Zig. It validates what a manifest says, records what happened, and fails clearly when compatibility is not implemented yet.

> **Status:** early development. The current milestone supports direct dependencies at exact versions and a source import checker. Expect the CLI and lockfile format to evolve.

## Why drml?

- **Native and focused:** a small Zig binary with no third-party Zig packages.

- **Explicit resolution:** exact `x.y.z` versions are validated instead of guessed around.

- **Inspectable state:** `drml-lock.json` records package versions and npm integrity metadata.

- **Useful feedback:** unsupported ranges, protocols, workspaces, and foreign lockfiles are explicit errors.

- **A wider direction:** the architecture leaves room for a resolver, store, linker, checker, compiler, test runner, and dev server.

## Install and build

Build from source with [Zig 0.15.2](https://ziglang.org/download/):

```
git clone https://github.com/drmlStudio/drml.git
cd drml
zig build
```

The default build creates a ready-to-pack directory at `zig-out/`:

```
zig-out/
├── bin/drml       # executable
├── package.json   # npm package manifest; bin.drml points to bin/drml
├── README.md
└── LICENSE
```

You can inspect or pack it with npm without publishing anything:

```
npm pack ./zig-out
```

For a local CLI run:

```
zig build run -- --help
```

## CLI reference

### Synopsis

```
drml [command] [options]
```

The CLI operates on the current working directory unless `init` is given an explicit directory. It reads `package.json`, writes `drml-lock.json`, and reports failures on stderr.

### Global flags

| Flag | Alias | Description |
| --- | --- | --- |
| `--help` | `-h` | Print the command summary and strict compatibility notes. It is also shown when no command is provided. |

There is currently **no ****`--version`**** flag**. Use the release tag or package metadata to identify a build.

### Commands

| Command | Options / arguments | Description |
| --- | --- | --- |
| `drml init` | `[directory]` | Create a minimal `package.json` in the current directory or in the optional directory. Accepts at most one directory. |
| `drml install` | none | Read `package.json`, validate exact versions, resolve registry metadata, write `drml-lock.json`, download direct packages, and extract them into `node_modules`. |
| `drml install` | `--lockfile-only` | Validate the manifest and generate `drml-lock.json` without downloading or extracting packages. This is useful for offline validation and CI fixture tests. |
| `drml check` | none | Scan JavaScript and TypeScript files for undeclared ESM imports, re-exports, CommonJS `require` calls, and literal dynamic `import( )` calls. Relative imports and Node built-ins are ignored. |

All other flags and positional arguments are rejected with `InvalidArguments`. Unknown commands are rejected with `UnknownCommand`.

### Manifest fields

The installer understands `dependencies`, `devDependencies`, `optionalDependencies`, `peerDependencies`, and `peerDependenciesMeta`. It caches downloaded archives in `.drml-cache/` and records development, optional, and peer flags in the lockfile.

Example:

```json
{
  "name": "my-app",
  "version": "0.1.0",
  "dependencies": {
    "typescript": "5.7.2"
  }
}
```

### Deliberate boundaries

The current milestone refuses to silently guess for:

- semver ranges and unsupported dependency protocols

- workspace roots and nested workspace packages

- npm, pnpm, Yarn, and Bun lockfiles until import adapters exist

- transitive dependency solving, executable shims, lifecycle scripts, and lockfile reuse

- browser-only WebAssembly without a separate host adapter

These are planned compatibility surfaces, not hidden behavior.

## Development

Run the unit tests, native build, WASI build, and fixture matrix:

```
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe
./drml/tests/run-fixtures.sh
```

The fixture corpus covers ordinary manifests, invalid shapes, exact-version failures, foreign lockfiles, workspaces, source checking, and regression cases. Registry-backed fixtures are opt-in:

```
DRML_LIVE_TESTS=1 ./drml/tests/run-fixtures.sh
./drml/tests/run-live-install.sh
```

Keep Zig formatting clean:

```
zig fmt --check build.zig drml/src
```

## Documentation site

The `website/` directory combines VitePress with Vue single-file components. VitePress supplies the static documentation shell and Vite-powered dev server; Vue components are registered through the VitePress theme and can be used directly in Markdown.

```
cd website
npm install
npm run dev       # local VitePress dev server
npm run build     # static site in docs/.vitepress/dist/
npm run typecheck
```

The site is intentionally plain-local and can be deployed to any static host. See the [website guide](website/README.md).

## Releases

Publishing a GitHub Release triggers `.github/workflows/release.yml`, which packages Linux x86_64/aarch64, macOS x86_64/aarch64, Windows x86_64, and WASI `wasm32-wasi` archives, as well as platform-specific npm packages.

## Contributing

Small, focused changes are welcome. Include a fixture for behavior changes, keep `zig fmt --check build.zig drml/src` clean, and explain intentional compatibility boundaries in the README or docs.

## License

[MIT](LICENSE)