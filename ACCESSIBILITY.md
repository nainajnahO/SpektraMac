# Accessibility

## The aim

SpektraMac aims to work with every accessibility feature macOS offers, as Apple's own apps do: VoiceOver, Voice
Control, Full Keyboard Access, Switch Control, Zoom, Increase Contrast, Reduce Transparency, Reduce Motion and
Differentiate Without Colour. It's built from the system's own controls wherever it can (see
[Native first](CONTRIBUTING.md#native-first)), and they bring most of this with them. Where a control is SpektraMac's
own, it should work as well as a system one. Anything that falls short is a bug, not a feature to ask for.

## Without seeing the screen

SpektraMac is about how a photo looks, and judging a film's look takes sight: VoiceOver can't describe how the colours
turned out. Everything else is meant to work without seeing the screen. VoiceOver names the film, the paper and every
setting, so opening a photo, adjusting it, using presets and film defaults, and saving should all work.

## Where it works

SpektraMac runs on macOS 26.5 or newer, with the accessibility features built into macOS (System Settings ›
Accessibility). Assistive technology from other makers hasn't been tried.

## New in the next release

From the release after 1.3:

- VoiceOver reads each group of settings by its name and whether it's open, and each slider's and strip's value with
  its unit, such as "+1.3 EV".
- It describes the photo by its file name, film and paper, and the tone graph as one item that says how its points
  print.
- On the Exposure strip, VoiceOver's actions (VO-Command-Space) go to each metering mark.
- Increase Contrast makes the sliders' fill and value line stronger.

This is new, so reports are especially welcome.

## Known limitations

- Holding a Burn slider to see what burns, and holding the Exposure strip to see what a mark meters, need a pointer:
  VoiceOver, Full Keyboard Access and Switch Control can't hold a control. The settings themselves work; only those
  previews are out of reach.
- In 1.3 and earlier, VoiceOver reads the settings poorly: a group's toggle without its name, and values without
  their units. The next release fixes it.
- Voice Control, Switch Control, Zoom, Reduce Transparency, Reduce Motion and Differentiate Without Colour haven't
  been checked one by one yet.

## Reporting a barrier

[Open an issue with the Accessibility barrier form](https://github.com/nainajnahO/SpektraMac/issues/new?template=accessibility.yml).
It asks what you were doing, what you were using and what got in the way, and labels the issue `accessibility`.
