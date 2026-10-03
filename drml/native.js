import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

/** Directory of the published wrapper package. */
export const wrapperDir = path.dirname(fileURLToPath(import.meta.url));

// A platform package owns exactly one executable. Keeping the package names in
// one place makes the runtime resolver and postinstall check agree.
const PLATFORMS = {
  win32: {
    x64: '@drml/x86_64-windows/bin/drml.exe',
    arm64: '@drml/aarch64-windows/bin/drml.exe',
  },
  darwin: {
    x64: '@drml/x86_64-macos/bin/drml',
    arm64: '@drml/aarch64-macos/bin/drml',
  },
  linux: {
    x64: {
      glibc: '@drml/x86_64-linux-gnu/bin/drml',
      musl: '@drml/x86_64-linux-musl/bin/drml',
    },
    arm64: {
      glibc: '@drml/aarch64-linux-gnu/bin/drml',
      musl: '@drml/aarch64-linux-musl/bin/drml',
    },
  },
};

/**
 * Return the native binary package(s) that can run on a host, in preference
 * order. The second Linux entry is only useful when a package manager was
 * forced to install both optional dependencies.
 */
export function getBinCandidates({
  platform = process.platform,
  arch = process.arch,
  libc = detectLinuxLibc(),
} = {}) {
  const platformEntry = PLATFORMS?.[platform]?.[arch];
  if (platformEntry == null) return [];

  if (typeof platformEntry === 'string') return [platformEntry];

  const detected = libc === 'musl' ? 'musl' : 'glibc';
  const preferred = platformEntry[detected];
  if (preferred == null) return [];

  const alternate = platformEntry[detected === 'musl' ? 'glibc' : 'musl'];
  return alternate == null ? [preferred] : [preferred, alternate];
}

/** Spell the current host in the same target format used by drml packages. */
export function hostTarget({
  platform = process.platform,
  arch = process.arch,
  libc = detectLinuxLibc(),
} = {}) {
  const cpu = arch === 'x64' ? 'x86_64' : arch === 'arm64' ? 'aarch64' : arch;
  if (platform === 'win32') return `${cpu}-windows`;
  if (platform === 'darwin') return `${cpu}-macos`;
  if (platform === 'linux') return `${cpu}-linux-${libc === 'musl' ? 'musl' : 'gnu'}`;
  return `${platform}-${arch}`;
}

/** Split a package/binary specifier into its npm package and binary path. */
export function splitBinSpecifier(specifier) {
  const [scope, name, ...rest] = specifier.split('/');
  return { packageName: `${scope}/${name}`, binFile: rest.join('/') };
}

/**
 * Locate the platform package selected by npm, pnpm, Yarn, or another Node
 * package manager. Only this package's own dependency locations are searched;
 * unrelated project dependencies are never executed.
 */
export function resolveInstalledBinary() {
  for (const specifier of getBinCandidates()) {
    const { packageName, binFile } = splitBinSpecifier(specifier);
    for (const modulesDir of installedModulesDirs()) {
      const candidate = path.join(modulesDir, ...packageName.split('/'), binFile);
      if (isRunnableFile(candidate)) return candidate;
    }
  }

  // `zig build` creates a self-contained development package in zig-out. A
  // published @drml/cli never includes this fallback; it uses optional native
  // dependencies above instead.
  const bundled = path.join(wrapperDir, 'bin', process.platform === 'win32' ? 'drml.exe' : 'drml');
  return isRunnableFile(bundled) ? bundled : null;
}

function installedModulesDirs() {
  const { name } = readWrapperManifest();
  const segments = typeof name === 'string' ? name.split('/').length : 1;
  return [
    path.join(wrapperDir, 'node_modules'),
    path.resolve(wrapperDir, ...Array(segments).fill('..')),
  ];
}

function readWrapperManifest() {
  const manifestPath = path.join(wrapperDir, 'package.json');
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(`Failed to read ${manifestPath}: ${error.message}`);
  }
  if (typeof manifest !== 'object' || manifest == null || Array.isArray(manifest)) {
    throw new Error(`Expected ${manifestPath} to contain a JSON object`);
  }
  return manifest;
}

function isRunnableFile(candidate) {
  const stats = fs.statSync(candidate, { throwIfNoEntry: false });
  if (stats?.isFile() !== true) return false;

  // Windows uses the executable extension. On POSIX, fail early with an
  // actionable package-installation error instead of a less clear EACCES.
  if (process.platform === 'win32') return true;
  try {
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function detectLinuxLibc() {
  if (process.platform !== 'linux') return null;

  // glibc binaries expose this field; musl does not. If a runtime does not
  // provide process.report, choose glibc, matching Node package-manager logic.
  try {
    return process.report?.getReport().header.glibcVersionRuntime ? 'glibc' : 'musl';
  } catch {
    return null;
  }
}
