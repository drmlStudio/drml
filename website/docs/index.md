---
layout: home
hero:
  name: drml
  text: A package manager with a point of view.
  tagline: Fast, explicit tooling for JavaScript and TypeScript — built in Zig, designed to fail clearly.
  image:
    src: /logo-wordmark-black.svg
    alt: drml logo
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/drmlStudio/drml
features:
  - icon: ⚡
    title: Small and fast
    details: A native Zig binary with no third-party Zig packages and a direct path from command to result.
  - icon: ◈
    title: Explicit by default
    details: Exact versions, visible lockfiles, integrity metadata, and clear refusal of unsupported protocols.
  - icon: ◎
    title: Built to grow
    details: A focused foundation for resolution, workspaces, stores, checkers, compilers, and dev tooling.
---

## The sharp edge is the feature

`drml` is an early, compatible slice of a new package-tooling stack. Today it installs direct dependencies at exact versions and audits imports. Tomorrow it can become the full development loop for JS and TS projects.

<div class="home-grid">

<div class="home-card">

### Install only what you mean

```sh
zig build run -- install
```

Exact-version manifests are validated instead of guessed around. The generated `drml-lock.json` records what happened.

</div>

<div class="home-card">

### Catch drift before runtime

```sh
drml check
```

Scan ESM imports, CommonJS `require`, and literal dynamic imports for packages missing from `package.json`.

</div>

</div>

## Current surface

- `install` — generate a lockfile or install direct registry packages
- `check` — find undeclared package imports
- `init` — create a minimal manifest
- WASI build target for host-adapted WebAssembly experiments

> drml refuses to silently guess. Unsupported ranges, protocols, foreign lockfiles, and workspace roots are surfaced as explicit errors while compatibility work lands.
