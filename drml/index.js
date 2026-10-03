#!/usr/bin/env node
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(__dirname, 'bin', 'drml.wasm');

const sourceExtensions = new Set(['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.mts', '.cts']);
const ignoredDirectories = new Set(['node_modules', '.git', 'dist', 'build', '.next', '.turbo', 'coverage', '.cache', 'test', 'tests']);
const nodeBuiltins = new Set([
  'assert', 'assert/strict', 'async_hooks', 'buffer', 'child_process', 'cluster', 'console', 'constants',
  'crypto', 'dgram', 'diagnostics_channel', 'dns', 'dns/promises', 'domain', 'events', 'fs', 'fs/promises',
  'http', 'http2', 'https', 'inspector', 'module', 'net', 'os', 'path', 'path/posix', 'path/win32',
  'perf_hooks', 'process', 'punycode', 'querystring', 'readline', 'readline/promises', 'repl', 'stream',
  'stream/consumers', 'stream/promises', 'stream/web', 'string_decoder', 'sys', 'test', 'test/reporters',
  'timers', 'timers/promises', 'tls', 'trace_events', 'tty', 'url', 'util', 'util/types', 'v8', 'vm',
  'wasi', 'worker_threads', 'zlib', 'sqlite', 'bun:test',
]);

function packageName(specifier) {
  if (!specifier || specifier.startsWith('.') || specifier.startsWith('/') || specifier.startsWith('#') || specifier.startsWith('node:') || specifier.startsWith('astro:')) return null;
  if (nodeBuiltins.has(specifier)) return null;
  if (specifier.startsWith('@')) {
    const first = specifier.indexOf('/');
    if (first < 0) return specifier;
    const second = specifier.indexOf('/', first + 1);
    return second < 0 ? specifier : specifier.slice(0, second);
  }
  const slash = specifier.indexOf('/');
  return slash < 0 ? specifier : specifier.slice(0, slash);
}

function importedPackages(source) {
  const withoutComments = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, '');
  const imports = new Set();
  const patterns = [
    /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /\bimport\s+['"]([^'"]+)['"]/g,
    /\b(?:import|export)\s+[^'"\n;]*?\bfrom\s*['"]([^'"]+)['"]/g,
  ];
  for (const pattern of patterns) {
    for (const match of withoutComments.matchAll(pattern)) {
      const name = packageName(match[1]);
      if (name) imports.add(name);
    }
  }
  return imports;
}

async function runNodeCheck() {
  const declared = new Set();
  async function collectManifests(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await collectManifests(path);
      } else if (entry.isFile() && entry.name === 'package.json') {
        const manifest = JSON.parse(await readFile(path, 'utf8'));
        for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
          for (const name of Object.keys(manifest[section] ?? {})) declared.add(name);
        }
      }
    }
  }
  await collectManifests('.');
  const violations = [];
  async function scan(directory, prefix = '') {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (entry.isDirectory() && ignoredDirectories.has(entry.name)) continue;
      const path = join(directory, entry.name);
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        await scan(path, relativePath);
      } else if (entry.isFile() && sourceExtensions.has(entry.name.slice(entry.name.lastIndexOf('.')))) {
        const source = await readFile(path, 'utf8');
        for (const name of importedPackages(source)) {
          if (!declared.has(name)) violations.push(`drml check: ${relativePath}: imported package '${name}' is not declared in package.json`);
        }
      }
    }
  }
  await scan('.');
  for (const violation of violations) console.error(violation);
  if (violations.length) return 1;
  console.error('drml check: no undeclared packages found');
  return 0;
}

if (process.argv[2] === 'check' && process.argv.length === 3) {
  try {
    process.exitCode = await runNodeCheck();
  } catch (error) {
    console.error(`error: ${error.code ?? error.message}`);
    process.exitCode = 1;
  }
} else {
const { WASI } = await import('node:wasi');
const wasi = new WASI({
  version: 'preview1',
  args: process.argv.slice(1),
  env: process.env,
  preopens: {
    '/': '.',
  },
});

const wasmBytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(wasmBytes, wasi.getImportObject());

try {
  const exitCode = wasi.start(instance);
  if (typeof exitCode === 'number' && exitCode !== 0) process.exitCode = exitCode;
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
}
