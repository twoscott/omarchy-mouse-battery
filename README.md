# 🔋 Omarchy Mouse Battery Widget

This is a wireless mouse battery indicator for the Omarchy bar. The bar shows a battery glyph whose
fill is the approximate level; clicking it opens a panel with the exact
percentage, charge state, when the mouse last reported, and an estimate of the
time remaining.

![Battery indicator preview](https://github.com/twoscott/omarchy-mouse-battery/blob/master/preview.png)

## 🖱️ Will it work with your mouse?

This widget shows what UPower already knows — it doesn't talk to your mouse
directly. Check before installing:

```bash
upower -e                    # list devices
upower -i <one of those paths>
```

If your mouse isn't listed, or is listed without a `percentage`, no bar widget
can help: the battery level isn't reaching your system at all.

| Mouse | Works |
|---|---|
| Logitech wireless — Unifying, Bolt, Lightspeed | ✅ |
| Bluetooth mice that expose a battery level | ✅ |
| Anything else your kernel exposes as a power supply | ✅ |
| Razer, Corsair, SteelSeries & co. on their **own 2.4 GHz dongles** | ❌ |

That last row is the common disappointment. Those mice report battery over a
vendor protocol only their own software understands (OpenRazer, ckb-next,
rivalcfg), and none of it reaches UPower. The same mouse connected over
**Bluetooth** often does work — worth trying.

## 💽 Install

```bash
omarchy plugin add https://github.com/twoscott/omarchy-mouse-battery.git --enable
omarchy restart shell
```

Add it to a bar section in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.twoscott.mouse-battery" }
```

## 🔨 Using it

| Input | Effect |
|---|---|
| left click | open/close the panel |
| right click | show/hide the percentage next to the bar glyph |
| middle click | refresh the panel now |

At or below the low threshold (20% by default, while discharging) the glyph and
the panel's reading turn your theme's urgent colour.

When the mouse is switched off it disappears from the system entirely, so the
widget hides itself. Set `hideWhenAbsent: false` to keep a dimmed slot instead.

## ⚙️ Settings

| Key | Default | What it does |
|---|---|---|
| `match` | `""` | Pick a specific device — see below. Empty means auto-detect. |
| `lowThreshold` | `20` | Percentage at which the reading turns urgent. |
| `showPercentage` | `false` | Show the percentage on the bar, not just in the panel. |
| `hideWhenAbsent` | `true` | Hide the widget when the mouse is off. |

You can add the widget more than once. A second entry with its own `match` gives
your keyboard — or a second mouse — its own pill:

```json
{ "id": "io.github.twoscott.mouse-battery", "match": "mx keys" }
```

Panel controls are also available over IPC:
`omarchy-shell io.github.twoscott.mouse-battery <open|close|toggle|togglePercentage>`.

## 🗑️ Remove

```bash
omarchy plugin remove io.github.twoscott.mouse-battery
```

## Picking the right device

Left alone, the widget finds your mouse by itself: it looks at how the system
classifies each wireless device, at how the device connects, and at its model
name (it knows the common Logitech, Razer, SteelSeries, Corsair and Glorious
mouse lines). Devices that are clearly something else — keyboards, headsets,
game controllers, your laptop's own battery — are left alone, and if two
devices tie, the choice is stable rather than dependent on connection order.

That guessing is not perfect, because not every system reports a mouse *as* a
mouse. If nothing shows up, or the wrong device does, name it yourself with
`match` — a case-insensitive fragment of the model name or device path from
`upower -i`:

```json
{ "id": "io.github.twoscott.mouse-battery", "match": "mx master" }
```

`match` overrides the guesswork completely, which is exactly what an
unrecognised mouse needs.

Not sure whether it's a matching problem or a hardware one? Set
`hideWhenAbsent: false` — a dimmed slot means "no device matched", nothing at
all means the widget isn't loaded.

## About the panel's readings

**Reported** is how long ago the mouse last sent a level. It matters more than
you'd think for a wireless device: a mouse asleep in a bag keeps showing its
last known level indefinitely, and this row tells you how stale that is.

**Time left / Time to full** is measured when your mouse provides it. Most mice
don't — they report a percentage and nothing else — so the widget works it
out from the level history the system keeps for the device, and marks it
with a `~`. It's shown only when there's enough recent data to justify it, so
expect a dash for the first while after a state change, and sometimes for good:
some mice don't report at all while charging, and some systems keep their
history logs private.

Everything else in the panel works regardless.
