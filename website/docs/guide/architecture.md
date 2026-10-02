# Architecture

The codebase is deliberately split into small responsibilities:

```text
src/
├── main.zig              # CLI parsing and command dispatch
├── package_manager.zig   # manifest, dependency validation, lockfiles, installs
└── package_checker.zig   # source scanning and undeclared-import diagnostics
```

The package manager owns manifest parsing, dependency-field merging, exact-version validation, registry metadata, tarball extraction, cache handling, and lockfile writing. The checker walks source trees while skipping dependencies, build output, and coverage directories.

## Roadmap

1. Transitive resolution, executable shims, lockfile reuse, and stronger integrity verification.
2. Complete semver solving with offline and frozen modes.
3. A pnpm-style content-addressed store and isolated linker.
4. Workspaces, peer solving, optional/platform dependencies, and lifecycle policy.
5. Scaffolding, compilation, test running, and development-server modules.
