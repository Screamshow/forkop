export interface MatchMetadata {
  host?: string;
  sniffHost?: string;
  destinationIP?: string;
}

function addressBytes(address: string): number[] | undefined {
  if (!address.includes(':')) {
    const parts = address.split('.');
    if (
      parts.length !== 4 ||
      parts.some((p) => !/^\d{1,3}$/.test(p) || Number(p) > 255)
    )
      return;
    return parts.map(Number);
  }
  // Expand an embedded IPv4 tail before expanding IPv6 compression.
  if (address.includes('.')) {
    const colon = address.lastIndexOf(':');
    const tail = addressBytes(address.slice(colon + 1));
    if (!tail) return;
    address = `${address.slice(0, colon)}:${((tail[0] << 8) | tail[1]).toString(16)}:${((tail[2] << 8) | tail[3]).toString(16)}`;
  }
  const halves = address.split('::');
  if (halves.length > 2) return;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if (halves.length === 1 ? missing !== 0 : missing < 1) return;
  const words = [...left, ...Array(missing).fill('0'), ...right];
  if (words.some((word) => !/^[\da-f]{1,4}$/i.test(word))) return;
  return words.flatMap((word) => {
    const value = parseInt(word, 16);
    return [value >> 8, value & 255];
  });
}

function inSubnet(address: string, subnet: string): boolean {
  const parts = subnet.split('/');
  const ip = addressBytes(address);
  const network = addressBytes(parts[0]);
  if (!ip || !network || ip.length !== network.length || parts.length > 2)
    return false;
  const bits = parts.length === 1 ? ip.length * 8 : Number(parts[1]);
  if (parts.length === 2 && !/^\d+$/.test(parts[1])) return false;
  if (bits < 0 || bits > ip.length * 8) return false;
  return ip.every((byte, index) => {
    const remaining = Math.max(0, Math.min(8, bits - index * 8));
    const mask = (255 << (8 - remaining)) & 255;
    return (byte & mask) === (network[index] & mask);
  });
}

export function matchedConditions(
  rule: string,
  metadata: MatchMetadata,
): string | undefined {
  // Inverted/logical expressions and opaque rule sets cannot be explained
  // reliably using the connection's final metadata.
  if (
    /\b(?:rule_set|invert)=|^\s*!?\s*(?:\(|(?:and|or)\()|\s(?:&&|\|\|)\s/.test(
      rule.replace(/\s*=>.*$/, ''),
    )
  )
    return;
  const host = (metadata.sniffHost || metadata.host || '')
    .toLowerCase()
    .replace(/\.$/, '');
  const matches: string[] = [];
  const conditions = rule.replace(/\s*=>.*$/, '');
  const fields = [...conditions.matchAll(/(?:^|\s)([a-z_]+)=/g)];
  for (const [index, field] of fields.entries()) {
    const kind = field[1];
    if (
      ![
        'domain',
        'domain_suffix',
        'domain_keyword',
        'domain_regex',
        'ip_cidr',
      ].includes(kind)
    )
      continue;
    const raw = conditions
      .slice(
        field.index! + field[0].length,
        fields[index + 1]?.index ?? conditions.length,
      )
      .trim();
    // Regex character classes contain brackets, so only remove the outer pair.
    const values =
      raw.startsWith('[') && raw.endsWith(']')
        ? raw.slice(1, -1).split(/\s+/)
        : [raw];
    for (const value of values) {
      if (!value || value.includes('...') || value.includes('…')) continue;
      const domain = value.toLowerCase().replace(/\.$/, '');
      let matched = false;
      if (kind === 'ip_cidr')
        matched = inSubnet(metadata.destinationIP || '', value);
      else if (host) {
        if (kind === 'domain') matched = host === domain;
        if (kind === 'domain_suffix')
          matched =
            host === domain ||
            host.endsWith(domain.startsWith('.') ? domain : `.${domain}`);
        if (kind === 'domain_keyword') matched = host.includes(domain);
        // RE2 and JavaScript differ. Skip syntax with incompatible semantics.
        if (
          kind === 'domain_regex' &&
          value.length <= 2048 &&
          host.length <= 253 &&
          !/\(\?|\)[*+{?]|\\[1-9]|\\[pP]|\[[:]/.test(value)
        ) {
          try {
            matched = new RegExp(value).test(
              metadata.sniffHost || metadata.host || '',
            );
          } catch {
            /* Preserve the original rule on unsupported syntax. */
          }
        }
      }
      if (matched) matches.push(`${kind}=${value}`);
    }
  }
  return matches.length ? [...new Set(matches)].join('; ') : undefined;
}
