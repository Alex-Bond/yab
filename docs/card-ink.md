# Words on a see-through card

The column put away and brought out over the page is a card (Peek.swift,
`Column`). With a see-through look it is composed as the window is, but
over the page rather than the desktop: the page under it blurred
(`ClearBand`, the material's tints stripped), a veil of white or black on
the color's side, the color or gradient at `1 - 0.84 t`, the grain. The
words on it are worked out from the color as if it were opaque (`Shades`).

## What went wrong

The veil was a fixed 0.2. A light color over a dark page then came out a
mid blue gray: #93A9F9 to #2AC8BB at transparency 0.51 over X's black page
is RGB 86, 124, 152 by the model above and 91, 121, 150 on the screen. The
navy words meant for #93A9F9 sank in it, 2.5 to 1 for a tab, 1.1 to 1 for
New tab, and 1.4 to 1 at full transparency.

## What was tried

An offscreen lab composed the card the same way, with SF at 14 points,
for four colors, four transparencies and five pages (X dark, white, YouTube
dark with thumbnails, a bright photograph, mid gray), and measured each
tier of words against the worst tenth of the ground under its row, 80
cases a variant:

| Variant | Muted under 4.5 | Faint under 2.5 | Page shows |
| --- | --- | --- | --- |
| The old card, veil 0.2 | 62 | 74 | 19 |
| A halo round the words | 62 | 74 | 19 |
| Ink from the ground as measured | 67 | 75 | 19 |
| White or black from the ground | 31 | 28 | 19 |
| The window's veil, 0.6 | 17 | 42 | 9 |
| The least veil for the swatch's words | 0 | 13 | 5 |
| A per-pixel luminance floor | 2 | 37 | 2 |
| Deep words and a floor | 1 | 2 | 13 |
| **Deep words and the least veil** | **0** | **0** | **12** |

"Page shows" is how much lighter the card is over white than over black,
in OKLab lightness × 100. Heavier type (medium, semibold) did not save the
old card at any weight. Ink worked out from what is under the card fails
because the page under a column is never one color: no single ink beats
both its light and its dark parts while the card is that clear.

## What Yab does

On a see-through card the words are the color's hue at the far end of its
lightness (`Shades.deep`): on a light color strong, muted and faint at
OKLCH 0.18, 0.26 and 0.44, on a dark one 0.99, 0.95 and 0.80, chroma at
most 0.11. The card's veil is the least, from 0.2 up, that keeps them at
4.5 and 2.6 to 1 over the worst page for the color's side, black under a
light color and white under a dark one, at every end of the gradient
(`BackdropVeil.cardVeil`). The custom color from the report gets 0.24 at
transparency 0.25, 0.46 at 0.51 and 0.58 at 1.

An opaque card, a glass one and a card under Reduce Transparency keep the
swatch's own shades and the 0.2 veil (`Tone.card`). The docked column is
untouched: it sits on the window's own backdrop and its 0.6 veil.

A floor that lifts only the dark of the page under a light color looks the
same and leaves light pages clear, but needs a filter on the private
backdrop layer. The veil is the card's own layer.

`BackdropInkTests` checks every preset, both appearances and the reported
gradient at five transparencies.
