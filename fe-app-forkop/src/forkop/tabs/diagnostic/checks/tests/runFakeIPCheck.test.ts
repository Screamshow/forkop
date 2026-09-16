import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkFakeIP: vi.fn(),
  getFakeIpCheck: vi.fn(),
  getIpCheck: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  ForkopShellMethods: { checkFakeIP: mocks.checkFakeIP },
  RemoteFakeIPMethods: {
    getFakeIpCheck: mocks.getFakeIpCheck,
    getIpCheck: mocks.getIpCheck,
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

vi.mock('../contstants', () => ({
  DIAGNOSTICS_CHECKS_MAP: {
    FAKEIP: { order: 8, code: 'FAKEIP', title: 'FakeIP checks' },
  },
}));

vi.mock('../../../../../helpers', () => ({
  insertIf: <T>(condition: boolean, elements: T[]) =>
    condition ? elements : [],
}));

import { runFakeIPCheck } from '../runFakeIPCheck';

describe('runFakeIPCheck', () => {
  beforeEach(() => {
    for (const mock of Object.values(mocks)) mock.mockReset();
    mocks.getFakeIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: true, IP: '203.0.113.10' },
    });
    mocks.getIpCheck.mockResolvedValue({
      success: true,
      data: { fakeip: false, IP: '203.0.113.10' },
    });
  });

  it('reports a successful skipped comparison when no proxy connection exists', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: {
        fakeip: true,
        public_ip_comparison_available: false,
        IP: '198.18.0.4',
      },
    });

    await runFakeIPCheck();

    expect(mocks.getIpCheck).not.toHaveBeenCalled();
    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'success',
        description:
          'FakeIP works; public IP comparison was skipped because no proxy connection is configured',
        items: expect.arrayContaining([
          expect.objectContaining({
            state: 'success',
            key: 'Public IP comparison skipped because no proxy connection is configured',
          }),
        ]),
      }),
    );
  });

  it('retains the warning when a proxy comparison returns the same public IP', async () => {
    mocks.checkFakeIP.mockResolvedValue({
      success: true,
      data: {
        fakeip: true,
        public_ip_comparison_available: true,
        IP: '198.18.0.4',
      },
    });

    await runFakeIPCheck();

    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'warning',
        description: 'FakeIP works; public IP comparison is inconclusive',
      }),
    );
  });
});
