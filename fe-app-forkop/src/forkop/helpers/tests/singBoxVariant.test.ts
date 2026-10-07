import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  formatSingBoxVersion,
  getSingBoxName,
  getSingBoxXVersion,
  normalizeSingBoxVariantFields,
} from '../singBoxVariant';
afterEach(() => vi.unstubAllGlobals());
describe('sing-box X identity', () => {
  it('shows X without stale Tiny and retains the upstream version', () => {
    vi.stubGlobal('_', (value: string) => value);
    const state = { sing_box_version: '1.14.2-x-1.0.0', sing_box_tiny: 1 };
    expect(getSingBoxName(state)).toBe('Sing-Box X');
    expect(formatSingBoxVersion(state)).toBe('1.0.0');
    expect(normalizeSingBoxVariantFields(state)).toMatchObject({
      sing_box_version: '1.14.2-x-1.0.0',
      sing_box_tiny: 0,
      sing_box_extended: 0,
    });
  });
  it('does not carry Extended-only capabilities over to X', () => {
    expect(
      normalizeSingBoxVariantFields({
        sing_box_version: '1.14.2-x-1.0.0',
        sing_box_extended: 1,
        sing_box_compressed: 1,
        sing_box_tailscale: 1,
      }),
    ).toMatchObject({
      sing_box_extended: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 0,
    });
  });
  it('preserves existing Tiny and Extended display', () => {
    vi.stubGlobal('_', (value: string) => value);
    expect(
      formatSingBoxVersion({ sing_box_version: '1.13.21', sing_box_tiny: 1 }),
    ).toBe('1.13.21 (tiny)');
    expect(
      formatSingBoxVersion({
        sing_box_version: '1.14.1-extended-2.7.2',
        sing_box_extended: 1,
        sing_box_compressed: 1,
      }),
    ).toBe('1.14.1-extended-2.7.2 (compressed)');
    expect(getSingBoxName({ sing_box_version: '1.13.21' })).toBe('Sing-box');
  });
  it('requires an explicit X version signature', () => {
    expect(getSingBoxXVersion('1.14.1-extended-2.7.2')).toBeUndefined();
    expect(getSingBoxXVersion('1.14.2')).toBeUndefined();
    expect(getSingBoxXVersion('1.14.2-x-1.1.0-rc.1')).toBe('1.1.0-rc.1');
  });
});
