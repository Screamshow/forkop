import { describe, expect, it } from 'vitest';
import { expandRouteConditions } from './routeConditions';
import { formatRouteReason } from './routeReason';

const reported =
  'inbound=[tproxy-in tproxy6-in] domain_suffix=[dell.com 2ip.io vencord.dev...] => route(VPN-out)';
const rule = {
  inbound: ['tproxy-in', 'tproxy6-in'],
  domain_suffix: ['dell.com', '2ip.io', 'vencord.dev', 'chatgpt.com'],
  action: 'route',
  outbound: 'VPN-out',
};

describe('full runtime route conditions', () => {
  it('recovers the omitted domain from the uniquely identified runtime rule', () => {
    const full = expandRouteConditions(reported, [rule]);
    expect(full).toContain('chatgpt.com');
    expect(
      formatRouteReason(full, '', undefined, { host: 'ws.chatgpt.com' }),
    ).toBe('domain_suffix=chatgpt.com');
  });
  it('keeps the reported rule when identification is ambiguous or impossible', () => {
    expect(
      expandRouteConditions(reported, [
        rule,
        { ...rule, domain_suffix: [...rule.domain_suffix, 'other.org'] },
      ]),
    ).toBe(reported);
    expect(
      expandRouteConditions(reported, [{ ...rule, outbound: 'other-out' }]),
    ).toBe(reported);
    expect(expandRouteConditions(reported, [])).toBe(reported);
  });
  it('checks all reported fields and recovers omitted CIDRs', () => {
    const text =
      'inbound=tproxy-in ip_cidr=[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16...] => route(VPN-out)';
    const full = expandRouteConditions(text, [
      {
        inbound: 'wrong-in',
        ip_cidr: [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '203.0.113.0/24',
        ],
        outbound: 'VPN-out',
      },
      {
        inbound: 'tproxy-in',
        ip_cidr: [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '203.0.113.0/24',
        ],
        outbound: 'VPN-out',
      },
    ]);
    expect(
      formatRouteReason(full, '', undefined, { destinationIP: '203.0.113.42' }),
    ).toBe('ip_cidr=203.0.113.0/24');
  });
});
