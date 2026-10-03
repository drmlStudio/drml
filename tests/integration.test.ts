import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '..');
const drmlBinary = process.env.DRML_BIN ?? join(repoRoot, 'zig-out', 'bin', process.platform === 'win32' ? 'drml.exe' : 'drml');
const projects: string[] = [];

function project(manifest: Record<string, unknown>): string {
  const directory = mkdtempSync(join(tmpdir(), 'drml-vitest-'));
  projects.push(directory);
  writeFileSync(join(directory, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return directory;
}

function runDrml(cwd: string, args: string[]) {
  const result = spawnSync(drmlBinary, args, {
    cwd,
    encoding: 'utf8',
    timeout: 120_000,
    windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`drml ${args.join(' ')} failed (${result.status})\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return { stdout: result.stdout, stderr: result.stderr };
}

function git(cwd: string, args: string[]) {
  execFileSync('git', args, { cwd, stdio: 'ignore' });
}

function createGitLifecycleFixture(): string {
  const fixture = mkdtempSync(join(tmpdir(), 'drml-git-fixture-'));
  projects.push(fixture);
  writeFileSync(join(fixture, 'package.json'), JSON.stringify({
    name: 'drml-script-fixture',
    version: '1.0.0',
    scripts: {
      postinstall: "node -e \"require('node:fs').writeFileSync('postinstall-marker', 'ran')\"",
    },
  }, null, 2) + '\n');
  git(fixture, ['init', '-q']);
  git(fixture, ['config', 'user.email', 'drml-tests@example.invalid']);
  git(fixture, ['config', 'user.name', 'drml tests']);
  git(fixture, ['add', 'package.json']);
  git(fixture, ['commit', '-q', '-m', 'fixture']);
  return fixture;
}

afterEach(() => {
  while (projects.length > 0) rmSync(projects.pop()!, { recursive: true, force: true });
});

describe('drml executable integration', () => {
  it('performs a real install and emits valid JSON', () => {
    const cwd = project({
      name: 'real-install-test',
      version: '1.0.0',
      private: true,
      dependencies: { 'is-number': '7.0.0' },
    });

    const result = runDrml(cwd, ['install', '--json']);
    const summary = JSON.parse(result.stdout);
    expect(summary).toMatchObject({ command: 'install', ok: true });
    expect(existsSync(join(cwd, 'node_modules', 'is-number', 'package.json'))).toBe(true);
    expect(JSON.parse(readFileSync(join(cwd, 'drml-lock.json'), 'utf8')).packages['is-number'].version).toBe('7.0.0');
  }, 120_000);

  it('routes add arguments around --dev and installs both groups', () => {
    const cwd = project({ name: 'add-test', version: '1.0.0', private: true });

    const result = runDrml(cwd, ['add', 'is-number', '--dev', 'is-odd', '--json']);
    const summary = JSON.parse(result.stdout);
    const manifest = JSON.parse(readFileSync(join(cwd, 'package.json'), 'utf8'));

    expect(summary).toMatchObject({ command: 'add', ok: true, dependencies: 1, devDependencies: 1 });
    expect(manifest.dependencies).toEqual({ 'is-number': 'latest' });
    expect(manifest.devDependencies).toEqual({ 'is-odd': 'latest' });
    expect(existsSync(join(cwd, 'node_modules', 'is-number', 'package.json'))).toBe(true);
    expect(existsSync(join(cwd, 'node_modules', 'is-odd', 'package.json'))).toBe(true);
  }, 120_000);

  it('skips lifecycle scripts by default and with --ignore-scripts', () => {
    const fixture = createGitLifecycleFixture();
    const source = pathToFileURL(fixture).href;
    const cwd = project({
      name: 'ignore-scripts-test',
      version: '1.0.0',
      private: true,
      dependencies: { 'drml-script-fixture': `git+${source}` },
    });

    runDrml(cwd, ['install']);
    expect(existsSync(join(cwd, 'node_modules', 'drml-script-fixture', 'postinstall-marker'))).toBe(false);

    rmSync(join(cwd, 'node_modules'), { recursive: true, force: true });
    rmSync(join(cwd, '.drml-cache'), { recursive: true, force: true });
    runDrml(cwd, ['install', '--ignore-scripts']);
    expect(existsSync(join(cwd, 'node_modules', 'drml-script-fixture', 'postinstall-marker'))).toBe(false);
  }, 120_000);

  it('runs lifecycle scripts and renders the script tree when requested', () => {
    const fixture = createGitLifecycleFixture();
    const source = pathToFileURL(fixture).href;
    const cwd = project({
      name: 'run-scripts-test',
      version: '1.0.0',
      private: true,
      dependencies: { 'drml-script-fixture': `git+${source}` },
    });

    const result = runDrml(cwd, ['install', '--run-scripts', '--verbose', '--json']);
    const summary = JSON.parse(result.stdout);
    expect(summary).toMatchObject({ command: 'install', ok: true, verbose: true });
    expect(result.stderr).toContain('[2] lifecycle');
    expect(result.stderr).toContain('script "postinstall"');
    expect(readFileSync(join(cwd, 'node_modules', 'drml-script-fixture', 'postinstall-marker'), 'utf8')).toBe('ran');
  }, 120_000);
});
