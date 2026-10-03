import { describe, expect, it } from 'vitest';
import { getBinCandidates, hostTarget, splitBinSpecifier } from '../../drml/native.js';

describe('native platform resolution', () => {
  it('selects the preferred Linux binary and keeps a fallback', () => {
    expect(getBinCandidates({ platform: 'linux', arch: 'x64', libc: 'glibc' })).toEqual([
      '@drml/x86_64-linux-gnu/bin/drml',
      '@drml/x86_64-linux-musl/bin/drml',
    ]);
  });

  it('spells supported host targets consistently', () => {
    expect(hostTarget({ platform: 'darwin', arch: 'arm64' })).toBe('aarch64-macos');
    expect(hostTarget({ platform: 'win32', arch: 'x64' })).toBe('x86_64-windows');
    expect(hostTarget({ platform: 'linux', arch: 'arm64', libc: 'musl' })).toBe('aarch64-linux-musl');
  });

  it('splits scoped package binary specifiers without losing subpaths', () => {
    expect(splitBinSpecifier('@scope/pkg/bin/drml')).toEqual({
      packageName: '@scope/pkg',
      binFile: 'bin/drml',
    });
  });
});
