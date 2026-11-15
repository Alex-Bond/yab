// These expected bytes are checked against the actual Swift Codable models.
// No real account data. The deliberately noncanonical ingress exercises optional
// nulls, unknown nested keys, integer aliases and strings the two encoders escape.
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const id = '00000000-0000-0000-0000-000000000007';
const words = 'café / 東京 \\ " \b\f\n\r\t\u0000\u001f \u2028\u2029 e\u0301 💡';
const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']' : value && typeof value === 'object'
  ? '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}' : JSON.stringify(value);
const fixture = (name, type, input, facts, numberLexeme) => {
  let body = canonical(facts);
  let source = JSON.stringify(input);
  if (numberLexeme) { body = body.replace('"date":1.25e-7', '"date":' + numberLexeme); source = source.replace('"date":1.25e-7', '"date":' + numberLexeme); }
  const prefix = type === 'request' ? 'yab assistant approval v1\n' : 'yab assistant detail v1\n';
  return { name, type, input: source, canonical: body, digest: createHash('sha256').update(prefix + body).digest('hex') };
};
const request = { id, account: 'test-account', mac: 'test-mac', assistant: 'claude', session: 'session', tab: 'chat:test',
  permit: 'mail.send', title: 'Claude: ' + words, lines: [words, 'https://site.test/a/b?x=1'], issued: 1700000000.125, expires: 1700003600 };
const requestInput = { ...request, seen: { device: 'test-mac', at: 1700000001 }, choices: null, future: { ignored: true } };
const file = { id: 'pdf', name: words, bytes: 9007199254740991, kind: 'pdf', pages: 2, previews: 1 };
const person = { name: words, address: 'me@example.test' };
const mail = { id: 'mail', from: person, to: [person], cc: [], bcc: [person], subject: words, body: words, files: [file], date: 1700000000.125 };
const pay = { site: 'https://site.test/a/b', item: words, amount: '$42.10', delivery: '', cards: [{ id: 'card', brand: 'Visa', last4: '4242', name: words }],
  places: [{ id: 'place', line: words, who: 'Home' }], card: 'card', place: 'place', takesCard: true, takesPlace: true };
const detail = { id, verb: 'Send / Pay', mails: [mail], pay, text: words, person };
const detailInput = { ...detail, files: null, unknown: true, person: { ...person, unknown: words }, pay: { ...pay, unknown: 42,
  cards: pay.cards.map(card => ({ ...card, unknown: 'ignored' })), places: pay.places.map(place => ({ ...place, unknown: 'ignored' })) },
  mails: [{ ...mail, from: { ...person, unknown: true }, to: [{ ...person, unknown: true }], cc: [],
    files: [{ ...file, width: null, height: null, unknown: true }], unknown: true }] };
const plain = { id, mails: [{ id: 'mail2', to: [{ name: 'A' }], cc: [], subject: '', body: words, files: [], date: 1.25e-7 }] };
const plainInput = { ...plain, verb: null, files: null, pay: null, text: null, person: null,
  mails: [{ ...plain.mails[0], from: null, bcc: null, to: [{ name: 'A', address: null, unknown: false }] }] };
const output = { format: 1, provenance: 'Reference bytes; verified by actual Swift AssistantApprovalRecords.Request and Detail Codable models', cases: [
  fixture('request-null-unknown-seen-and-escaping', 'request', requestInput, request),
  fixture('request-choices-and-integral-double', 'request', { ...request, issued: 1700000000, choices: [words, 'other'], future: null }, { ...request, issued: 1700000000, choices: [words, 'other'] }),
  fixture('detail-full-mail-payment-nested-unknown-and-null', 'detail', detailInput, detail),
  fixture('detail-exponent-and-optional-nulls', 'detail', plainInput, plain, '1.25e-07'),
  fixture('detail-negative-zero', 'detail', { id, mails: [{ ...plain.mails[0], date: -0 }] }, { id, mails: [{ ...plain.mails[0], date: -0 }] }),
] };
// Swift's Double keeps the sign of zero; JavaScript JSON.stringify does not.
output.cases[4].input = output.cases[4].input.replace('"date":0', '"date":-0');
output.cases[4].canonical = output.cases[4].canonical.replace('"date":0', '"date":-0');
output.cases[4].digest = createHash('sha256').update('yab assistant detail v1\n' + output.cases[4].canonical).digest('hex');
writeFileSync(process.argv[2] ?? fileURLToPath(new URL('./approval-vectors-v1.json', import.meta.url)), JSON.stringify(output, null, 2) + '\n');
