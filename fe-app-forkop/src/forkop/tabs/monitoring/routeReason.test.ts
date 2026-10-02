import { describe, expect, it } from 'vitest';
import { formatRouteReason } from './routeReason';

describe('route reason', () => {
  it('shows a compact fallback for the reproduced domain connection with a missing destination IP', () => {
    const rule =
      'inbound=test-in domain_suffix=[bhvr.com bhvronline.com deadbydaylight.com] domain_regex=^gamelift-ping\\.[a-z0-9-]+\\.api\\.aws$ ip_cidr=[18.184.209.26 18.185.240.169 127.0.0.1] => route(DBD-out)';
    const metadata = {
      host: 'valorant.secure.dyn.riotcdn.net',
      destinationIP: '',
    };
    expect(formatRouteReason(rule, '', undefined, metadata)).toBe(
      'Exact match unavailable',
    );
    expect(
      formatRouteReason(
        rule,
        '',
        (text) =>
          text === 'Exact match unavailable'
            ? 'Точное совпадение недоступно'
            : text,
        metadata,
      ),
    ).toBe('Точное совпадение недоступно');
    expect(
      formatRouteReason(rule, '', undefined, {
        ...metadata,
        destinationIP: '127.0.0.1',
      }),
    ).toBe('ip_cidr=127.0.0.1');
  });
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
