# Getting started

`drml` is currently built from source with Zig 0.15.2. The repository includes the CLI, fixture corpus, and release packaging scripts.

## Build from source

```sh
git clone https://github.com/drmlStudio/drml.git
cd drml
zig build
```

Run the CLI help:

```sh
zig build run -- --help
```

## Create a manifest

```sh
zig build run -- init
```

Then add exact-version dependencies to `package.json`:

```json
{
  "name": "my-app",
  "version": "0.1.0",
  "dependencies": {
    "typescript": "5.7.2"
  }
}
```

## Install and audit

```sh
zig build run -- install
zig build run -- check
```

Use `install --lockfile-only` when you want to validate the manifest and generate `drml-lock.json` without downloading packages.

## Run the test corpus

```sh
zig build test
./tests/run-fixtures.sh
```

The fixture runner covers dependency fields, package-manager metadata, invalid manifests, foreign lockfiles, workspace refusal, checker behavior, and regression cases.
