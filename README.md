![Logo](./assets/logo-drml-black.svg)

# drml

[![CI](https://img.shields.io/github/actions/workflow/status/drmlStudio/drml/ci.yml?branch=main&label=CI)](https://github.com/drmlStudio/drml/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/@drml/cli)](https://www.npmjs.com/package/@drml/cli)
[![License](https://img.shields.io/github/license/drmlStudio/drml)](LICENSE)
[![Built with Zig](https://img.shields.io/badge/built%20with-Zig-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Docs](https://img.shields.io/badge/docs-VitePress-646CFF?logo=vitepress&logoColor=white)](https://github.com/drmlStudio/drml/tree/main/website)

`drml` is a package manager for JavaScript and TypeScript projects, written in Zig. It reads `package.json`, resolves registry dependencies (including transitives), writes an inspectable `drml-lock.json`, and installs packages into `node_modules`.

> **Status:** early development. The CLI and lockfile format are still evolving. The current implementation handles workspace packages, Git dependencies, common semver/prerelease ranges, npm-style script hooks, and a source import checker.

## Install and build

Build from source with [Zig 0.15.2](https://ziglang.org/download/):

```
git clone https://github.com/drmlStudio/drml.git
cd drml
zig build
```

The default build creates a ready-to-pack native development directory at `zig-out/`:

```
zig-out/
├── bin/drml       # native executable for the host
├── package.json   # npm package manifest; bin.drml points to index.js
├── index.js        # finds and runs the native executable
├── native.js       # host/platform package resolver
├── install.js      # package installation verifier
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

Commands operate on the current working directory unless `init` receives a directory argument. Install reads `package.json`, writes `drml-lock.json`, and reports errors on stderr.

### Flags

| Flag | Commands | Description |
| --- | --- | --- |
| `--help` | global | Print the command summary. `-h` is an alias. It is also shown when no command is provided. |
| `--lockfile-only` | `install` | Validate the manifest and write `drml-lock.json` without downloading or extracting packages. |
| `--include-dev` | `install` | Include root and workspace `devDependencies`. This is the default. |
| `--omit-dev` | `install` | Exclude root and workspace `devDependencies`. |
| `--include-optional-peers` | `install` | Include optional peer dependencies. Optional peers are omitted by default. |
| `--run-scripts` | `install` | Run dependency `preinstall`, `install`, and `postinstall` scripts after extraction. Scripts are ignored by default. |

`--version` prints the CLI version. Errors return a non-zero exit code, including from the npm native launcher.

### Commands

| Command | Arguments | Description |
| --- | --- | --- |
| `drml init` | `[directory]` | Create a minimal `package.json` in the current directory or in the optional directory. |
| `drml install` | flags listed above | Read the manifest, resolve packages, write `drml-lock.json`, download registry archives, and extract them into `node_modules`. |
| `drml check` | none | Scan JavaScript and TypeScript files for undeclared ESM imports, re-exports, CommonJS `require` calls, and literal dynamic `import( )` calls. Relative imports and Node built-ins are ignored. |
| `drml build` | none | Run the `build` script from `package.json`. |
| `drml run` | `<script> [args...]` | Run a named script from `package.json`. |
| `drml exec` | `<command> [args...]` | Run a command directly without looking it up in `package.json`. |

Unknown commands and unsupported positional arguments return `InvalidArguments` or `UnknownCommand` as appropriate.

## `package.json` support

The installer reads these dependency fields:

- `dependencies`

- `devDependencies`

- `optionalDependencies`

- `peerDependencies`

- `peerDependenciesMeta`

Repeated package names across these sections are combined into one lockfile entry. The first declaration supplies the requested version; later declarations contribute their `dev`, `optional`, and `peer` markers. This prevents a package listed with, for example, `^22.15.3` in one section and `22.15.3` in another from failing with `ConflictingDependencySpec`.

Common exact and partial versions and semver ranges such as caret (`^22.15`), tilde (`~22.15`), prereleases (`^4.0.0-rc.1`), comparator sets (`>=22.0 <23.0.0`), wildcards, and `||` alternatives are supported during registry resolution. Git URLs and `workspace:` dependencies are also recognized where applicable.

Existing npm, pnpm, Yarn, Bun, and npm shrinkwrap lockfiles are left in place and do not prevent drml from generating `drml-lock.json`. drml does not import their contents yet; `drml-lock.json` is its own lockfile.

Example:

```json
{
  "name": "my-app",
  "version": "0.1.0",
  "dependencies": {
    "typescript": "^5.7.2"
  }
}
```

## Current limitations

The current resolver does not yet provide:

- reuse/import of npm, pnpm, Yarn, or Bun lockfiles

- executable shims for every package-manager edge case

- browser-only WebAssembly without a separate host adapter

- complete npm semver behavior, including every exotic protocol form

These are implementation notes for the current release, not restrictions on the presence of another package manager's lockfile.

## Development

Run the unit tests, native build, and fixture matrix:

```
zig build test
zig build -Doptimize=ReleaseSafe
./drml/tests/run-fixtures.sh
```

The fixture corpus covers ordinary manifests, semver ranges, duplicate dependency declarations, foreign lockfiles, workspaces, transitive dependencies, script hooks, source checking, and regression cases. Registry-backed fixtures are opt-in:

```
DRML_LIVE_TESTS=1 ./drml/tests/run-fixtures.sh
./drml/tests/run-live-install.sh
```

The live matrix also includes small real-world-style projects for transitive dependencies, prerelease and `=` ranges, scoped packages, workspace links, optional dependencies, and npm-compatible CLI script hooks. This keeps the end-to-end checks fast while covering behavior that large repositories often expose.

Keep Zig formatting clean:

```
zig fmt --check build.zig drml/src
```

## Releases

Publishing a GitHub Release triggers `.github/workflows/release.yml`. It publishes `@drml/cli` plus native optional-dependency packages for `x86_64-windows`, `aarch64-windows`, `aarch64-macos`, `x86_64-macos`, `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`, and `aarch64-linux-musl`.

Install the CLI with npm, pnpm, or Yarn:

```
npm install -g @drml/cli
```

The package manager selects the matching native `@drml/*` optional dependency. The `drml` launcher verifies that binary and runs it. Reinstall without `--omit=optional` or `--no-optional` if the platform binary was intentionally skipped.

## Contributing

Small, focused changes are welcome. Include a fixture for behavior changes, keep `zig fmt --check build.zig drml/src` clean, and document user-visible CLI behavior in the README or website docs.

## License

[MIT](LICENSE)