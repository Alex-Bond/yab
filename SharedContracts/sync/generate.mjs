// Deterministic test fixtures only. Never use these keys or nonces in an app.
// Verify the output independently against Sources/SyncKit with verify-swift/main.swift.
import { createHash, createHmac, hkdfSync, pbkdf2Sync, createCipheriv, createPrivateKey, createPublicKey, diffieHellman } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const utf8 = s => Buffer.from(s, 'utf8');
const hex = b => Buffer.from(b).toString('hex');
const b64 = b => Buffer.from(b).toString('base64');
const url64 = b => Buffer.from(b).toString('base64url');
const sha = b => createHash('sha256').update(b).digest();
const hkdf = (key, info, size = 32, salt = Buffer.alloc(0)) => Buffer.from(hkdfSync('sha256', key, salt, utf8(info), size));
const mac = (key, body) => createHmac('sha256', key).update(body).digest();
const raw = Buffer.from(Array.from({ length: 32 }, (_, n) => n));
const nonce = Buffer.from('000102030405060708090a0b', 'hex');
function aes(key, body, aad = Buffer.alloc(0)) {
  const cipher = createCipheriv('aes-256-gcm', key, nonce); cipher.setAAD(aad);
  return Buffer.concat([nonce, cipher.update(body), cipher.final(), cipher.getAuthTag()]);
}
function base32(bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let buffer = 0, bits = 0, out = '';
  for (const byte of bytes) { buffer = (buffer << 8) | byte; bits += 8; while (bits >= 5) { out += alphabet[(buffer >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits) out += alphabet[(buffer << (5 - bits)) & 31];
  return out.match(/.{1,4}/g).join('-');
}
const privateKey = bytes => createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), bytes]), format: 'der', type: 'pkcs8' });
const publicRaw = key => createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32);
const rootFields = { title: 'A café / 東京', seen: 123.5, enabled: true, nothing: null, future: { nested: ['x', 2, false] } };
const record = { collection: 'tab', id: '00000000-0000-0000-0000-000000000002', fields: rootFields,
  stamps: Object.fromEntries(Object.keys(rootFields).map(key => [key, { wall: 1700000000000, count: 3, device: 'mac-a' }])), schema: 1 };
const name = url64(mac(hkdf(raw, 'yab sync names v1'), utf8(`${record.collection}\0${record.id}`)));
const secretKey = 'login/site.test\x01me'; const secretBody = utf8('pāssword 💡');
const code = 'K7QM-4XTD', normal = 'K7QM4XTD';
const master = pbkdf2Sync(utf8(normal), utf8('yab sync pairing v2'), 300000, 32, 'sha256');
const receiverPrivate = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 32));
const senderPrivate = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 64));
const receiver = privateKey(receiverPrivate), sender = privateKey(senderPrivate), receiverPublic = publicRaw(receiver);
const posted = Buffer.concat([receiverPublic, mac(hkdf(master, 'pub'), Buffer.concat([utf8('yab sync pub v2'), receiverPublic]))]);
const pairingShared = diffieHellman({ privateKey: sender, publicKey: createPublicKey(receiver) });
const envelopeKey = hkdf(pairingShared, 'yab sync join v2', 32, hkdf(master, 'envelope'));
const check = String(sha(Buffer.concat([utf8(`yab sync check v1\0${normal}\0`), receiverPublic])).readUInt32BE(0) % 10000).padStart(4, '0');
const output = {
  format: 1, provenance: 'Node crypto reference; independently checked by Swift SyncKit harness',
  root: { hex: hex(raw), account: url64(hkdf(raw, 'yab sync account v1', 16)), auth: url64(hkdf(raw, 'yab sync auth v1')),
    recovery: base32(Buffer.concat([raw, sha(raw).subarray(0, 2)])), recordsKey: hex(hkdf(raw, 'yab sync records v1')), namesKey: hex(hkdf(raw, 'yab sync names v1')) },
  record: { json: JSON.stringify(record), name, sealed: b64(aes(hkdf(raw, 'yab sync records v1'), utf8(JSON.stringify(record)), utf8(name))) },
  secret: { key: secretKey, text: secretBody.toString('utf8'), sealed: b64(aes(hkdf(raw, 'yab sync secrets v1'), secretBody, utf8(secretKey))) },
  pairing: { code, receiverPrivate: hex(receiverPrivate), receiverPublic: hex(receiverPublic), senderPrivate: hex(senderPrivate),
    posted: b64(posted), box: hex(hkdf(master, 'box')), check,
    envelope: b64(Buffer.concat([publicRaw(sender), aes(envelopeKey, raw)])) },
  order: [ { after: null, before: null, key: 'V' }, { after: 'V', before: null, key: 'W' }, { after: null, before: 'V', key: 'U' },
    { after: 'A', before: 'B', key: 'AV' }, { after: 'z', before: null, key: 'zV' }, { after: null, before: '1', key: '0z' },
    { after: 'A', before: 'A1', key: 'A0V' } ],
};
writeFileSync(process.argv[2] ?? fileURLToPath(new URL('./vectors-v1.json', import.meta.url)), JSON.stringify(output, null, 2) + '\n');
