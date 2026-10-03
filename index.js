#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { WASI } from 'node:wasi';

const __dirname = dirname(fileURLToPath(import.meta.url));
const wasmPath = join(__dirname, 'bin', 'drml.wasm');

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

wasi.start(instance);