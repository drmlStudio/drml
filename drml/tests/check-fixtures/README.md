# Package checker fixtures

- `clean`: declared packages, scoped subpaths, CommonJS, dynamic imports, re-exports, built-ins, relative imports, comments, strings, and ignored `node_modules` content.
- `missing`: undeclared ESM, re-export, CommonJS, and dynamic imports. The checker must report each normalized package name.
