// Synthetic transport facts. Swift's production TaskRecords is the independent oracle.
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
const canonical = value => value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}' : JSON.stringify(value);
const base = { version: 1, id: '00000000-0000-0000-0000-000000000020', account: 'test-account', phone: 'test-android', mac: 'test-mac', space: 'test-space', words: 'Read café / 東京 \\ "\n 💡', created: 1700000000 };
const cases = [
  ['legacy-omitted-nil', base],
  ['readonly-public-space', { ...base, readOnlyEpoch: '00000000-0000-0000-0000-000000000021' }],
  ['readonly-tab-fraction', { ...base, created: 1700000000.125, tab: 'test-tab', url: 'https://site.test/a/b?q=caf%C3%A9', title: 'Quoted " title / 東京', readOnlyEpoch: '00000000-0000-0000-0000-000000000021' }],
].map(([name, facts]) => {
  const body = canonical(facts);
  const digest = createHash('sha256').update('yab task request v1\n' + body).digest('hex');
  const observation = canonical({ version: 1, task: facts.id, requestDigest: digest, account: facts.account, phone: facts.phone, mac: facts.mac, revision: 4294967296, session: 'session', status: 'done', title: 'Actual Mac title', progress: 'Read three pages', result: '# Actual result\n\ncafé / 東京', resultURL: 'https://site.test/result' });
  return { name, input: JSON.stringify({ ignored: 'forward-field', ...facts, ...(facts.tab ? {} : { tab: null, url: null, title: null }), ...(facts.readOnlyEpoch ? {} : { readOnlyEpoch: null }) }), canonical: body, digest, observation };
});
writeFileSync(new URL('task-vectors-v1.json', import.meta.url), JSON.stringify({ version: 1, cases }, null, 2) + '\n');
