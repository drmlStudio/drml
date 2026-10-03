#!/usr/bin/env node
import { spawn } from 'node:child_process';
import process from 'node:process';
import { getBinCandidates, hostTarget, resolveInstalledBinary, splitBinSpecifier } from './native.js';

let binary;
try {
  binary = resolveInstalledBinary();
} catch (error) {
  console.error(`drml: failed to locate its native binary: ${error.message}`);
  process.exitCode = 1;
}

if (binary == null && process.exitCode == null) {
  const packages = getBinCandidates().map((candidate) => splitBinSpecifier(candidate).packageName);
  const expected = packages.length === 0 ? 'no supported native package' : packages.join(' or ');
  console.error(`drml: no native binary is installed for ${hostTarget()} (expected ${expected}).`);
  console.error('Reinstall @drml/cli without --omit=optional or --no-optional so the platform package can be installed.');
  process.exitCode = 1;
}

if (binary != null) {
  const child = spawn(binary, process.argv.slice(2), {
    stdio: 'inherit',
    windowsHide: true,
  });

  child.on('error', (error) => {
    console.error(`drml: failed to start ${binary}: ${error.message}`);
    process.exitCode = 1;
  });

  child.on('close', (code, signal) => {
    if (signal != null) {
      console.error(`drml: native binary terminated by ${signal}`);
      process.exitCode = 1;
      return;
    }
    process.exitCode = code ?? 1;
  });
}
