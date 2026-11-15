# Packs Resources/emoji.dat, the words Emoji (EmojiMeaning.swift) finds an
# emoji by, from Unicode CLDR's English annotations: its name and keywords.
# The folder holding cldr-json's annotations/en comes as the argument, from
# https://github.com/unicode-org/cldr-json (cldr-annotations-full).
# A line an emoji: glyph and its words, tab apart, the words | apart, the
# spoken name first; raw deflate over the whole, as bins.dat.
import json, sys, zlib
table = json.load(open(f'{sys.argv[1]}/en/annotations.json'))['annotations']['annotations']
lines = [glyph + '\t' + '|'.join(dict.fromkeys(w.strip() for w in v.get('tts', []) + v.get('default', []))) for glyph, v in table.items()]
c = zlib.compressobj(9, zlib.DEFLATED, -15)
open('Resources/emoji.dat', 'wb').write(c.compress('\n'.join(lines).encode()) + c.flush())
print(len(lines), 'emoji')
