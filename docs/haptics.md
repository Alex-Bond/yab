# Haptics

What the trackpad can play, measured from the framework that plays it.

## What the actuator can do

Yab's Knock (`Sources/Fast/LookSlider.swift`) reaches the actuator through
MultitouchSupport, a private framework:
`MTActuatorActuate(actuator, id, flags, Float, Float)`. The framework carries
its own table of waveforms, a property list in section
`__TEXT,__tpad_act_plist`, one list per kind of actuator (`Actuator_1` to
`Actuator_15`, and `Default`). Read from it and from the code that uses it,
on macOS 27:

- Every waveform, ids 1 to 6, is one Gaussian push of 5 to 7 ms with a few
  faint tones on top; they differ only in amplitude. On this MacBook Pro
  (`Actuator_10`) ids 1 and 3 are 19, 5 is 23, 2 and 4 are 35, 6 is 48.
  Ids 15 and 16 have no push at all, only a tone.
- The first float scales the push's amplitude; the framework then holds it
  between 14 and 70. The second scales its length, held between 4 and 8 ms.
  Zero, which Knock passes, leaves both as the table has them, and also
  drops the tones.
- Flags 1, 2 and 4 pick the Light, Medium and Firm multipliers that follow
  the Click setting in System Settings; flag 8 picks an id's Silent variant
  where one exists.
- So nothing longer than 8 ms is one push: a longer feel is a train of them.
  One call takes about 4 ms, so pushes 6 to 10 ms apart are within reach.
- The actuator kind is read at offset 0x44 of the opened actuator, private
  and only trusted while it looks sane; `Default`
  stands in otherwise.

Knock plays id 6, the firmest: amplitude 48 and 6 ms.

NSHapticFeedbackManager's patterns, the rest of what Yab plays, take no
strength and play only while a finger is on the trackpad.
