#!/usr/bin/env node
// Generate the content-only resource. Dependencies live outside the checkout.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const versions = {terser: '5.51.2', acorn: '8.16.0'};
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const args = process.argv.slice(2);
const check = args.includes('--check');
const toolsAt = args.indexOf('--tools');
const tools = toolsAt < 0
  ? path.join(os.homedir(), 'Library/Caches/Yab/extension-content-tools', `${versions.terser}-${versions.acorn}`)
  : path.resolve(args[toolsAt + 1]);
const require = createRequire(path.join(tools, 'package.json'));
function installed() {
  try {
    return Object.entries(versions).every(([name, version]) => require(`${name}/package.json`).version === version);
  } catch { return false; }
}
if (!installed()) {
  if (toolsAt >= 0) throw new Error('--tools must contain the exact pinned terser/acorn versions');
  fs.mkdirSync(tools, {recursive: true});
  const setup = spawnSync('npm', ['install', '--prefix', tools, '--no-save', '--package-lock=false',
    '--ignore-scripts', '--no-audit', '--no-fund', ...Object.entries(versions).map(([n, v]) => `${n}@${v}`)],
    {stdio: 'inherit'});
  if (setup.status !== 0 || !installed()) throw new Error('could not install pinned content generator outside checkout');
}
const {minify} = require('terser');
const acorn = require('acorn');
const sha = text => crypto.createHash('sha256').update(text).digest('hex');

// Byte-for-byte counterpart of ExtensionShims.contentPart(of:). The Swift
// regression binds this intermediate hash, so neither pruner can drift alone.
function contentPart(script) {
  const end = script.indexOf('if (inContent) return;');
  if (end < 0) throw new Error('content return marker missing');
  const head = script.slice(0, end);
  const whole = head + '})();\n';
  const kept = [];
  let skipping = null;
  for (const line of head.split('\n')) {
    if (skipping !== null) {
      if (line === skipping) skipping = null;
      else if (line.startsWith(skipping + ' else')) return whole;
      continue;
    }
    const bare = line.replace(/^ +/, '');
    const worker = bare.startsWith('if (worker') || bare.startsWith('if (!inContent');
    if (worker && bare.endsWith('{') && !bare.includes('}')) {
      skipping = ' '.repeat(line.length - bare.length) + '}';
      continue;
    }
    kept.push(line);
  }
  return skipping === null ? kept.join('\n') + '})();\n' : whole;
}

function normalize(value) {
  if (typeof value === 'bigint') return ['BigInt', value.toString()];
  if (!value || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(normalize);
  return Object.fromEntries(Object.entries(value)
    .filter(([key]) => !['start', 'end', 'loc', 'raw'].includes(key))
    .map(([key, member]) => [key, normalize(member)]));
}
const ast = text => JSON.stringify(normalize(acorn.parse(text, {ecmaVersion: 'latest', sourceType: 'script'})));
const flags = ['__YAB_DCL_LATE__', '__YAB_PORT_TRACE__', '__YAB_PORT_SLOW__'];
const input = path.join(root, 'Resources/PageScripts/extension-shims.js');
const target = path.join(root, 'Resources/PageScripts/extension-content.min.js');
// PageScript.load drops exactly one trailing newline.
const load = file => { const text = fs.readFileSync(file, 'utf8'); return text.endsWith('\n') ? text.slice(0, -1) : text; };
// ExtensionShims.script inlines the legacy file system shim (e2f1dd03):
// the source hash is of that string, as Swift has it.
const source = load(input).replaceAll('__YAB_FILE_SYSTEM__',
  load(path.join(root, 'Resources/PageScripts/legacy-file-system.js')));
const content = contentPart(source);
const found = [...new Set(content.match(/__YAB_[A-Z_]+__/g) || [])].sort();
if (JSON.stringify(found) !== JSON.stringify([...flags].sort())) throw new Error('content placeholders changed; update native binding explicitly');
const options = {compress: false, mangle: false, ecma: 2022,
  format: {comments: false, semicolons: true, beautify: false, ascii_only: false}};
const {code} = await minify(content, options);
if (ast(content) !== ast(code)) throw new Error('template AST changed');
for (let mask = 0; mask < 8; mask++) {
  const bind = text => flags.reduce((value, flag, index) => value.replaceAll(flag, mask & (1 << index) ? 'true' : 'false'), text);
  if (ast(bind(content)) !== ast(bind(code))) throw new Error(`AST changed for flag combination ${mask}`);
}
const header = `/* yab-extension-content source-sha256=${sha(source)} content-sha256=${sha(content)} */\n`;
const generated = header + code + '\n';
if (check) {
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== generated) {
    throw new Error('extension-content.min.js is stale; run node scripts/extension-content-generate.mjs');
  }
} else {
  fs.writeFileSync(target, generated);
}
console.log(JSON.stringify({check, versions, compress: false, mangle: false,
  source_sha256: sha(source), content_sha256: sha(content),
  full_source_bytes: Buffer.byteLength(source), content_bytes: Buffer.byteLength(content),
  min_payload_bytes: Buffer.byteLength(code), generated_resource_bytes: Buffer.byteLength(generated),
  original_utf16_pages: Math.ceil(content.length * 2 / 16384),
  min_utf16_pages: Math.ceil(generated.length * 2 / 16384), ast_equal: true, boolean_variants_checked: 8}));
