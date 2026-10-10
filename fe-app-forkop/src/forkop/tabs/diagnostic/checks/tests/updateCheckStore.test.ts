import { describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ get: vi.fn(), set: vi.fn() }));
vi.mock('../../../../services', () => ({ store: mocks }));
import { updateCheckStore } from '../updateCheckStore';
import { DIAGNOSTICS_CHECKS } from '../contstants';

describe('diagnostic core labels', () => {
  it.each([
    ['1.14.2-rust-x.0.0.5', 'Rust X'],
    ['1.14.2-x-1.0.3', 'Sing-Box X'],
    ['1.14.2', 'Sing-box'],
  ])('renders %s without changing diagnostic results', (version, name) => {
    mocks.get.mockReturnValue({
      diagnosticsSystemInfo: { sing_box_version: version },
      diagnosticsChecks: [],
    });
    const check = {
      code: DIAGNOSTICS_CHECKS.SINGBOX,
      order: 2,
      title: 'Sing-box checks',
      description: 'Problems detected',
      state: 'error' as const,
      items: [
        {
          key: 'Процесс sing-box запущен',
          state: 'error' as const,
          value: '/usr/bin/sing-box',
        },
      ],
    };
    updateCheckStore(check);
    expect(mocks.set).toHaveBeenLastCalledWith({
      diagnosticsChecks: [
        {
          ...check,
          title: `${name} checks`,
          items: [{ ...check.items[0], key: `Процесс ${name} запущен` }],
        },
      ],
    });
    expect(check.title).toBe('Sing-box checks');
    expect(check.items[0].key).toBe('Процесс sing-box запущен');
  });
});
