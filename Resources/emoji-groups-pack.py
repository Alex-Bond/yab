# Packs Resources/emoji-groups.dat, the emoji Change Icon's picker lists
# (IconPicker.swift), in Unicode's own order for keyboard palettes under the
# eight parts Apple's picker and Arc's have. From Unicode's emoji-test.txt
# (https://unicode.org/Public/emoji/latest/emoji-test.txt), the argument:
# fully qualified only, no skin tones, nothing newer than Emoji 16.0, the
# last macOS 15.4 draws.
# A part is a line of its own, "#" and its title; an emoji a line of its
# glyph and its name, tab apart; raw deflate over the whole, as emoji.dat.
import re, sys, zlib
parts = {'Smileys & Emotion': 'Smileys & People', 'People & Body': 'Smileys & People',
         'Animals & Nature': 'Animals & Nature', 'Food & Drink': 'Food & Drink', 'Activities': 'Activity',
         'Travel & Places': 'Travel & Places', 'Objects': 'Objects', 'Symbols': 'Symbols', 'Flags': 'Flags'}
order = ['Smileys & People', 'Animals & Nature', 'Food & Drink', 'Activity', 'Travel & Places', 'Objects', 'Symbols', 'Flags']
listed = {title: [] for title in order}
group = None
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('# group:'):
        group = parts.get(line.split(':', 1)[1].strip())
        continue
    found = re.search(r'; fully-qualified\s+# (\S+) E(\d+\.\d+) (.+)$', line)
    if not found or group is None:
        continue
    glyph, version, name = found.group(1), float(found.group(2)), found.group(3).strip()
    if version > 16.0 or 'skin tone' in name:
        continue
    listed[group].append(glyph + '\t' + name)
lines = []
for title in order:
    lines.append('#' + title)
    lines += listed[title]
c = zlib.compressobj(9, zlib.DEFLATED, -15)
open('Resources/emoji-groups.dat', 'wb').write(c.compress('\n'.join(lines).encode()) + c.flush())
print(sum(len(v) for v in listed.values()), 'emoji')
