import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { parse } from '@babel/parser';

const require = createRequire(import.meta.url);
const generate = require('@babel/generator').default;
const metadata = new Set([
  'start', 'end', 'loc', 'extra', 'comments', 'tokens',
  'leadingComments', 'trailingComments', 'innerComments',
]);

function semanticAst(code: string) {
  return JSON.stringify(parse(code, { allowReturnOutsideFunction: true }),
    (key, value) => metadata.has(key) ? undefined : value);
}

// Handwritten LuCI sources keep their readable form. Both package builders
// overlay these generated files, including their top-level return/directives.
export function compactLuCIAssets() {
  const source = path.resolve('../luci-app-forkop/htdocs/luci-static/resources/view/forkop');
  const output = path.resolve('../luci-app-forkop/generated/luci-static/resources/view/forkop');
  fs.mkdirSync(output, { recursive: true });
  let originalBytes = 0, compactBytes = 0;
  const sourceHashes: string[] = [];
  for (const name of fs.readdirSync(source).filter(name => name.endsWith('.js') && name !== 'main.js').sort()) {
    const code = fs.readFileSync(path.join(source, name), 'utf8');
    const compact = generate(parse(code, { allowReturnOutsideFunction: true }), {
      compact: true, comments: false,
    }).code + '\n';
    assert.ok(semanticAst(compact) === semanticAst(code), `LuCI semantics changed: ${name}`);
    fs.writeFileSync(path.join(output, name), compact);
    originalBytes += Buffer.byteLength(code);
    compactBytes += Buffer.byteLength(compact);
    sourceHashes.push(`${createHash('sha256').update(code).digest('hex')}  htdocs/luci-static/resources/view/forkop/${name}`);
  }
  fs.writeFileSync(path.resolve('../luci-app-forkop/generated/source.sha256'), sourceHashes.join('\n') + '\n');
  console.log(`LuCI handwritten assets: ${originalBytes} -> ${compactBytes} bytes`);
}
