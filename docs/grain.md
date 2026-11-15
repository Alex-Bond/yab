# Grain

A space's color can wear a paper texture, and how much of it is a share
from 0 (none) to 1 (roughest). It is set on a track under the lightness's
wave, and the trackpad ticks as it moves.

## The tracks

Arc sets grain on a knob, and Yab did too (`GrainDial`), but a knob is
poor under a mouse: it looks turned and is dragged, and its drag (right
minus down) cancelled itself on a diagonal. Now the lightness and the
grain are two `LookSlider`s (LookSlider.swift), handled alike: the pill is
taken where it's held, a press on the track glides it there, ⌥ slows a
drag to a quarter, a scroll more sideways than up or down moves it with
the fingers (any other goes on to the page), a double click puts it back
(the lightness to what the editor opened on, the grain to the standard),
and a label over the pill says how much while it's pointed at or held.
The lightness's track is Arc's wave, flat past the pill; the grain's a
scatter of dots that thickens to the right, dark as far as the pill. The
grain rounds to twentieths, as Arc's dial did.

There is no row of preset colors anywhere. As in Arc (and as in the
open-source Vane, whose editor this follows), a look is set in one editor,
`ColorEditor` (SpaceLook.swift): a rounded field printed with a fine grid
of dots, each in the color the handle would give there (at the light
window's shade even in a dark look, where the deepened colors read as
black), swelling near the handle as under a lens, hue across and how much
color down, the color's own dot ringed in
white and dragged across it; under it the lightness on a wave that
flattens past its pill, and the grain's track under it. Settings has no
page of its own for a look: it opens from a dot of its color, in a
popover, as New Space's card shows it (`LookPicker`). With two spaces or
more each space's look is its own, the dot on that space's page in
Spaces, and Appearance's Look row opens the page of the space on screen.
With spaces off, or only one, the window's look is Appearance's, the dot
on its Look row. The welcome has a Color chapter
of its own after Your look; New Space has it as a step of its own, after the name, and
while it and the sign-ins step are up the window itself wears the new
look over its own (SpaceWash), as Arc's does: back to the name or closed,
the window's own comes back; made, the space's stays. Spaces already in a preset keep it; the
editor starts from the preset's color and moving it makes the color your
own.

## The ticks

`Detents.crossed(old, new, every:)` says whether a change met a mark, a
whole multiple of the step, either end counted, and `Detents.tick()` plays
`NSHapticFeedbackManager`'s `.generic` pattern at once. The grain ticks on
every twentieth: each step meets a tenth at one end. The lightness
wave ticks at each fifth of the way. Run into either end, both knock
instead (`Knock`): the trackpad actuator's firmest waveform, reached
through the private MultitouchSupport framework since the public
patterns have no strength, `.levelChange` where it won't open. Only a Force Touch trackpad
plays them, and only while the finger is down, which a drag is.

## What Arc does

Read from Arc 1.166's binary (`SpaceStyleEditor`): the grain dial
(`noiseFactor`) rounds to `round(v * 20) / 20` and plays `.generic`, `.now`
whenever the change meets a multiple of 0.1, both ends counted, so every
step ticks. The intensity slider (`intensityFactor`, a sine wave along the
track) is continuous and ticks where it meets a multiple of 0.2. The color
pad has no haptics. Arc also has four textures (grain, sand, denim, tweed),
cycled by clicking the knob; Yab has its one.

Bringing Arc's spaces in takes their `noiseFactor` as the amount.

## Stored

`backdrop.grain.amount` in the preferences and `grainAmount` in a space's
paint. Both still write on or off under the old keys (`backdrop.grain`,
`grain`), so a build from before the amount reads them as it did; an
old "on" reads here as the standard, 0.35, which is the 0.07 opacity grain
always had.
