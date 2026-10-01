import { describe, expect, it } from 'vitest';
import { formatRouteReason } from './routeReason';

describe('route reason', () => {
  it('names the matching built-in list, including hyphenated sections', () => {
    expect(
      formatRouteReason(
        'inbound=tproxy-in rule_set=my-vpn-discord-community-ruleset => route(my-vpn-out)',
      ),
    ).toBe('Discord');
  });
  it('does not guess which member of a legacy combined rule matched', () => {
    expect(
      formatRouteReason(
        'rule_set=[VPN-discord-community-ruleset VPN-telegram-community-ruleset] => route(VPN-out)',
      ),
    ).toBe('One of: Discord, Telegram');
  });
  it('preserves inline conditions and custom rule-set identifiers', () => {
    expect(
      formatRouteReason('domain_suffix=example.org => route(VPN-out)'),
    ).toBe('domain_suffix=example.org');
    expect(
      formatRouteReason('rule_set=inline-custom-123-ruleset => route(VPN-out)'),
    ).toBe('inline-custom-123-ruleset');
  });
  it('distinguishes absent metadata from a reported default route', () => {
    expect(formatRouteReason()).toBe('Not available');
    expect(formatRouteReason('final')).toBe('Default route');
  });
});
