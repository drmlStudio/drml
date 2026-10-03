#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { getBinCandidates, hostTarget, resolveInstalledBinary, splitBinSpecifier } from './native.js';

const wrapperDir = path.dirname(fileURLToPath(import.meta.url));

try {
  if (resolveInstalledBinary() == null) {
    const candidates = getBinCandidates();
    if (candidates.length === 0) {
      throw new Error(
        `No released native binary is available for ${hostTarget()} on this platform.`
      );
    }

    const packages = candidates.map((candidate) => splitBinSpecifier(candidate).packageName);
    console.error(`@drml/cli: native binary missing for ${hostTarget()}.`);

    if (!(await shouldInstallManually())) {
      throw new Error(
        `Binaries missing; manual installation declined. Reinstall @drml/cli without --omit=optional or --no-optional.`
      );
    }

    await installManually(packages[0]);

    if (resolveInstalledBinary() == null) {
      throw new Error(
        `Manual installation finished, but no runnable native binary was found. Expected ${packages.join(' or ')}.`
      );
    }

    console.error('@drml/cli: native binary installed successfully.');
  }
} catch (error) {
  console.error(`@drml/cli installation failed: ${error.message}`);
  process.exitCode = 1;
}

async function shouldInstallManually() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error('Binaries missing, but this installation has no interactive terminal.');
    return false;
  }

  const answer = await ask('Binaries missing, want to install manually? [y/N] ');
  return /^(?:y|yes)$/i.test(answer.trim());
}

function ask(question) {
  const prompt = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  return new Promise((resolve) => {
    prompt.question(question, (answer) => {
      prompt.close();
      resolve(answer);
    });
  });
}

async function installManually(packageName) {
  const manifest = JSON.parse(fs.readFileSync(path.join(wrapperDir, 'package.json'), 'utf8'));
  const version = manifest.version;
  if (typeof version !== 'string' || version.length === 0) {
    throw new Error('Cannot determine the @drml/cli version for manual binary installation.');
  }

  const spec = `${packageName}@${version}`;
  console.error(`@drml/cli: downloading ${spec} directly from the npm registry...`);

  const metadataUrl = `https://registry.npmjs.org/${encodeURIComponent(packageName)}`;
  const metadataResponse = await fetch(metadataUrl, {
    headers: { accept: 'application/json' },
  });
  if (!metadataResponse.ok) {
    throw new Error(`Registry returned HTTP ${metadataResponse.status} for ${packageName}.`);
  }

  const metadata = await metadataResponse.json();
  const tarballUrl = metadata.versions?.[version]?.dist?.tarball;
  if (typeof tarballUrl !== 'string') {
    throw new Error(`Registry has no tarball for ${spec}.`);
  }

  const tarballResponse = await fetch(tarballUrl);
  if (!tarballResponse.ok) {
    throw new Error(`Registry returned HTTP ${tarballResponse.status} for ${tarballUrl}.`);
  }

  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'drml-cli-'));
  const tarballPath = path.join(temporaryDirectory, 'package.tgz');
  const extractDirectory = path.join(temporaryDirectory, 'extract');
  fs.mkdirSync(extractDirectory);
  try {
    fs.writeFileSync(tarballPath, Buffer.from(await tarballResponse.arrayBuffer()));
    const result = spawnSync('tar', ['-xzf', tarballPath, '-C', extractDirectory], {
      stdio: 'inherit',
    });
    if (result.error) throw new Error(`Could not extract the native package: ${result.error.message}`);
    if (result.status !== 0) throw new Error(`tar exited with status ${result.status ?? 'unknown'}.`);

    const packageDirectory = path.join(extractDirectory, 'package');
    if (!fs.statSync(packageDirectory, { throwIfNoEntry: false })?.isDirectory()) {
      throw new Error('The downloaded tarball did not contain a package directory.');
    }

    const packageNameWithoutScope = packageName.slice(packageName.lastIndexOf('/') + 1);
    const destination = path.join(wrapperDir, 'node_modules', '@drml', packageNameWithoutScope);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.rmSync(destination, { recursive: true, force: true });
    fs.renameSync(packageDirectory, destination);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}