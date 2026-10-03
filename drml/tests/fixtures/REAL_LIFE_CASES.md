# Real-life regression fixtures

These fixtures intentionally use package names and dependency forms found in real repositories:

- `real-transitive`: `is-odd@3.0.1` brings `is-number` transitively; `semver` exercises the local `.bin` PATH from a script.
- `real-prerelease`: `std-env@^4.0.0-rc.1` exercises prerelease range parsing and `@oxc-project/types@=0.133.0` exercises npm's exact-range prefix.
- `real-workspace`: two scoped workspace packages exercise workspace links, workspace manifests, and transitive resolution from a workspace package.
- `real-scoped`: `@babel/runtime@7.27.6` plus an optional dependency exercises scoped tarball URLs and optional package installation.
- `real-cli-script`: `semver@7.7.4` exercises `pretest`, `test`, `posttest`, and the local `node_modules/.bin` PATH.

They are network-backed and run only when `DRML_LIVE_TESTS=1` is set.
