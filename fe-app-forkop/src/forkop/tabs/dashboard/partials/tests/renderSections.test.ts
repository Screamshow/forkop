import { describe, expect, it } from 'vitest';

import { Forkop } from '../../../../types';
import { getOutboundFooterLabel } from '../getOutboundFooterLabel';

function outbound(options: Partial<Forkop.Outbound>): Forkop.Outbound {
  return {
    code: 'proxy',
    displayName: 'proxy',
    latency: 0,
    type: 'VLESS',
    selected: false,
    ...options,
  };
}

describe('getOutboundFooterLabel', () => {
  it('shows the active URLTest member instead of the group type', () => {
    expect(
      getOutboundFooterLabel(
        outbound({
          urlTestInfo: {
            code: 'auto',
            displayName: 'Automatic',
            selectedName: 'edge-7.nl.cdn-store.cloud',
            outbounds: [],
          },
        }),
      ),
    ).toBe('edge-7.nl.cdn-store.cloud');
  });

  it('shows Server Description for a regular host and falls back to protocol', () => {
    expect(
      getOutboundFooterLabel(outbound({ description: 'Upstream Tube' })),
    ).toBe('Upstream Tube');
    expect(getOutboundFooterLabel(outbound({}))).toBe('VLESS');
  });
});
