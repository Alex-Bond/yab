import csv, re, struct, zlib, sys
rows = list(csv.DictReader(open(sys.argv[1])))
OVERRIDE = {
 'JPMORGAN CHASE BANK': 'Chase', 'CAPITAL ONE': 'Capital One', 'BANK OF AMERICA': 'Bank of America',
 'CITIBANK': 'Citi', 'WELLS FARGO BANK': 'Wells Fargo', 'U.S. BANK': 'U.S. Bank', 'AMERICAN EXPRESS': 'American Express',
 'DISCOVER': 'Discover', 'DISCOVER BANK': 'Discover', 'SBERBANK OF RUSSIA': 'Sberbank', 'STRIPE PAYMENTS UK': 'Stripe',
 'GOLDMAN SACHS BANK USA': 'Goldman Sachs', 'SYNCHRONY BANK': 'Synchrony', 'BARCLAYS BANK DELAWARE': 'Barclays',
 'TINKOFF BANK': 'T-Bank', 'JOINT STOCK COMPANY TINKOFF BANK': 'T-Bank', 'REVOLUT': 'Revolut', 'MONZO BANK': 'Monzo',
}
CAPS = set('HSBC ICICI HDFC BPCE UBS BNP TD RBC BMO CIBC ING ABN KB BBVA CIMB DBS OCBC UOB SBI PNC USAA TSB NAB ANZ CBA BMW BC DC JCB AIB BOC ICBC CCB VTB OTP UBL MCB NBG CIC LCL IDBI UCO BCP BCI BCR BRD RBS NBK QNB ADCB FAB USA UK N26'.split())
SMALL = {'OF', 'THE', 'AND', 'DE', 'DU', 'DES', 'LA', 'DEL', 'DI', 'Y', 'E', 'FOR'}
TAIL = re.compile(r'(,?\s*(NATIONAL ASSOCIATION|N\.A\.?|LLC|L\.L\.C\.|INC\.?|LTD\.?|LIMITED|CO\.,? LTD\.?|PLC|GMBH|AG|S\.A\.?|S\.P\.A\.?|SPA|CORP\.?|CORPORATION|FSB|ISSUER|US CONSUMER|US CARS|- CONSUMER CREDIT|- CONSUMER)\s*)+$')
def clean(name):
    n = name.strip().upper()
    if not n: return ''
    for _ in range(3): n = TAIL.sub('', n).strip(' ,-')
    if n in OVERRIDE: return OVERRIDE[n]
    out = []
    for i, w in enumerate(n.split()):
        bare = w.strip('(),.&')
        if bare in CAPS or (len(bare) <= 3 and not re.search('[AEIOUY]', bare) and bare.isalpha()): out.append(w)
        elif i > 0 and w in SMALL: out.append(w.lower())
        else: out.append('-'.join(p[:1] + p[1:].lower() for p in w.split('-')))
    return ' '.join(out)
LEVELS = {'PLATINUM': 'Platinum', 'GOLD': 'Gold', 'WORLD': 'World', 'WORLD ELITE': 'World Elite', 'SIGNATURE': 'Signature',
          'INFINITE': 'Infinite', 'BLACK': 'Black', 'TITANIUM': 'Titanium', 'BUSINESS': 'Business', 'CORPORATE': 'Corporate',
          'SMALL BUSINESS': 'Business', 'PREPAID': 'Prepaid', 'PREPAID CLASSIC': 'Prepaid', 'PREPAID RELOADABLE': 'Prepaid',
          'PREPAID PLATINUM': 'Prepaid', 'PREPAID BUSINESS': 'Prepaid', 'GIFT': 'Gift', 'CENTURION': 'Centurion', 'WORLD BLACK': 'World Black'}
TYPES = {'CREDIT': 1, 'DEBIT': 2, 'CHARGE CARD': 3}
issuers = ['']; ix = {'': 0}
levels = [''] + sorted(set(LEVELS.values())); lx = {v: i for i, v in enumerate(levels)}
recs = []
for r in rows:
    name = clean(r['Issuer'])
    if name not in ix: ix[name] = len(issuers); issuers.append(name)
    lv = LEVELS.get(r['Category'].strip().upper(), '')
    recs.append((int(r['BIN']), ix[name], lx[lv], TYPES.get(r['Type'].strip().upper(), 0)))
recs.sort()
def strings(ss):
    b = struct.pack('<I', len(ss))
    for s in ss:
        e = s.encode(); b += struct.pack('<H', len(e)) + e
    return b
raw = b'BIN1' + strings(issuers) + strings(levels) + struct.pack('<I', len(recs)) + b''.join(struct.pack('<IHBB', *r) for r in recs)
c = zlib.compressobj(9, zlib.DEFLATED, -15)
out = c.compress(raw) + c.flush()
open(sys.argv[2], 'wb').write(out)
print(len(issuers), len(recs), len(raw), len(out))
for b in [414720, 517805, 440066, 424242, 555555, 371449]:
    r = next(x for x in recs if x[0] == b); print(b, issuers[r[1]], levels[r[2]], r[3])
import random
print(random.sample(issuers, 25))
