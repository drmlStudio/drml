# Commands

## `drml init [directory]`

Create a minimal `package.json`. An optional directory lets you initialize a project without changing directories first.

## `drml install`

Read `package.json`, validate exact versions, resolve registry metadata, download direct packages, write `drml-lock.json`, and extract packages into `node_modules`.

Use `--lockfile-only` to stop after lockfile generation. This is the mode used by the offline fixture suite.

## `drml check`

Scan JavaScript and TypeScript files for undeclared package imports. The checker understands static ESM imports, re-exports, CommonJS `require`, and literal dynamic `import()` calls. Relative imports and Node built-ins are ignored.

## Current boundaries

The current milestone intentionally refuses:

- semver ranges and unsupported dependency protocols
- workspace roots and nested workspace packages
- foreign lockfiles until import adapters exist
- transitive dependency solving and lifecycle scripts
- browser-only WebAssembly without a WASI host adapter
