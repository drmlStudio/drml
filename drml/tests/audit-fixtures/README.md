# Audit regression fixtures

These fixtures correspond directly to the attached correctness audit:

- malformed non-object manifests
- JSON escaping in lockfiles
- duplicate dependency merging and conflicting specs
- scoped package tarball URLs
- leading-zero version rejection
- extra CLI arguments
- regex literals containing import-like text
- multiline imports
- comments between import syntax tokens

The executable assertions for these fixtures live in `tests/run-fixtures.sh`. They verify both failure diagnostics and generated lockfile contents, including valid JSON escaping, merged duplicate keys, and the correct scoped-package tarball basename.
