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
    details: Semver ranges, visible lockfiles, integrity metadata, and clear diagnostics for unsupported protocols.
  - icon: ◎
    title: Built to grow
    details: A focused foundation for resolution, workspaces, stores, checkers, compilers, and dev tooling.
---

## A small, inspectable package manager

`drml` is an early, compatible slice of a new package-tooling stack. Today it installs direct dependencies, writes its own lockfile, and audits imports. The CLI and lockfile format will continue to grow.

<CapabilityGrid :items="[
  { title: 'Inspect every install', description: 'The generated drml-lock.json records resolved versions, sources, and integrity metadata.', command: 'zig build run -- install' },
  { title: 'Catch drift before runtime', description: 'Scan ESM imports, CommonJS require, and literal dynamic imports for packages missing from package.json.', command: 'drml check' }
]" />

## Current surface

- `install` — generate a lockfile or install direct registry packages
- `check` — find undeclared package imports
- `init` — create a minimal manifest
- Native npm packages for Windows, macOS, Linux glibc, and Linux musl targets

> drml writes its own lockfile without importing or deleting npm-family lockfiles. Unsupported protocols and incomplete compatibility areas are surfaced as explicit errors.
