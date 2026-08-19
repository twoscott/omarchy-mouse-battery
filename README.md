# Mouse Battery

Wireless mouse battery for the Omarchy bar: an icon-only pill whose glyph fill
is the approximate level, and a click-through panel with the exact percentage,
charge state, how long ago the mouse last reported, and an estimated time
remaining fitted from UPower's own charge log.

```
manifest.json   plugin + settings schema
Panel.qml       bar pill and popup (single bar-widget entry point)
Model.js        pure device-matching and formatting helpers
```

## Will it work with your mouse?

**This widget can only show what UPower already knows.** It reads
`Quickshell.Services.UPower`; it does not talk to your mouse. Before installing,
run:

```bash
upower -e                    # list devices
upower -i <one of those paths>
```

If your mouse is not in that list, or is listed without a `percentage`, no bar
widget can help — the battery level is not reaching the system in the first
place.

| Mouse | Works |
|---|---|
| Logitech wireless — Unifying, Bolt, Lightspeed — via the kernel `hid-logitech-hidpp` driver | ✅ |
| Bluetooth mice exposing the BLE Battery Service (through BlueZ) | ✅ |
| Anything else exporting a `/sys/class/power_supply/*` node UPower picks up | ✅ |
| Razer, Corsair, SteelSeries & co. over their **proprietary 2.4 GHz dongles** | ❌ |

That last row is the common disappointment. Those mice report their battery over
a vendor protocol that only a userspace daemon (OpenRazer, ckb-next, rivalcfg,
Solaar for non-hid++ paths) understands, and none of them publish it to UPower.
The same mouse connected over **Bluetooth** often does work — worth trying.

If UPower sees your mouse but the widget stays blank, it is a matching problem,
not a hardware one: set `match` (below), or set `hideWhenAbsent: false` to keep
a dimmed slot on the bar so you can tell "mouse switched off" apart from "no
device matched".

## Install

```bash
omarchy plugin add https://github.com/twoscott/omarchy-mouse-battery.git --enable
```

Then add it to a bar section in `~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.twoscott.mouse-battery" }
```

Enabling a plugin needs `omarchy restart shell` before the bar slot
instantiates it. Editing one afterwards hot-reloads.

## Settings

| Key | Default | What it does |
|---|---|---|
| `match` | `""` | Case-insensitive substring matched against the UPower model *and* kernel path. Empty auto-detects. |
| `lowThreshold` | `20` | At or below this percentage, glyph and panel reading turn urgent. |
| `showPercentage` | `false` | Show the reading beside the bar glyph. Right-click toggles it. |
| `hideWhenAbsent` | `true` | Collapse the slot when the mouse is off. `false` keeps a dimmed slot. |

`allowMultiple` is true, so a second entry with a different `match` gives a
keyboard (or a second mouse) its own pill:

```json
{ "id": "io.github.twoscott.mouse-battery", "match": "mx keys" }
```

| Input | Effect |
|---|---|
| left | open/close the panel |
| right | toggle the exact percentage beside the bar glyph |
| middle | re-poll `upower` for the panel's freshness fields |

IPC: `omarchy-shell io.github.twoscott.mouse-battery <open\|close\|toggle\|togglePercentage>`.

## Device matching

The point of the `Model.deviceScore` heuristic is that **device type is not
trustworthy here**. UPower's hid++ backend has been seen reporting a G Pro
Wireless as `Type=6` — *Keyboard*, not Mouse — and a Bluetooth mouse whose
appearance byte says nothing arrives as `Type=Unknown`. So the score is built
from signals that do hold:

| Signal | Weight |
|---|---|
| `type == Mouse` | +4 |
| `nativePath` contains `hidpp` | +3 |
| model matches a pointing-device name (`mouse`, `trackball`, `mx master`, `deathadder`, `aerox`, `model o`, `m720`, …) | +2 |

Two gates sit in front of that score:

- Devices with `powerSupply: true` are excluded outright — the machine's own
  battery and AC line power belong to `omarchy.power`.
- A device UPower has *positively typed as something else* — Keyboard, Headset,
  GamingInput — only competes if its model name says mouse. A hid++ keyboard and
  a wireless headset ride the same transport as the mouse, so `hidpp` alone must
  not be allowed to vouch for them. `Unknown` and a bare `Battery` on a
  `scope=Device` node are not such claims; they are UPower saying it does not
  know, and those devices do compete.

Anything scoring zero is never picked, so an Xbox controller (`gip0.0`) and a
laptop battery stay out of it. Equal scores break deterministically — genuine
Mouse type first, then lowest native path — so a receiver carrying both a mouse
and a keyboard resolves the same way on every start rather than by enumeration
order.

Set `match` to override the heuristic entirely with a case-insensitive substring
of the model or kernel path:

```json
{ "id": "io.github.twoscott.mouse-battery", "match": "mx master" }
```

An explicit `match` **skips every gate above** except the `powerSupply` one.
That is deliberate: a device UPower could not classify is exactly the case where
the user has to be able to say "that one".

## Why the panel shells out to `upower`

Level and charge state arrive over D-Bus through
`Quickshell.Services.UPower` — push-based, no polling, and the bar glyph is
driven entirely from that.

What the Quickshell binding does not expose is **when the device last
reported**, and for a wireless peripheral that is the difference between "23%"
and "23% as of two hours ago, and it has been asleep in a drawer since". That
field only exists on the CLI, so the panel polls `upower -i` every 15s *while
open* and prints it as `Reported`.

The D-Bus path is resolved by reading each device's `native-path` rather than by
constructing it: the mapping is not a stable string transform —
`hidpp_battery_1` lives at `…/devices/battery_hidpp_battery_1`, with a
`battery_` prefix UPower applies regardless of the type it reported.

## Time remaining is fitted, not reported

`timeToFull` / `timeToEmpty` are 0 on most mouse hardware. UPower derives them
as *energy needed ÷ energy rate*, and the hid++ driver exports neither — the
whole power_supply node is:

```
$ ls /sys/class/power_supply/hidpp_battery_1/
capacity  status  voltage_now  online  scope  type  model_name  serial_number
```

No `energy_now`, no `power_now`. UPower's own rate log for the device is
correspondingly all zeros, so there is nothing to read.

But UPower *does* keep a charge log — one `<epoch> <percentage> <state>` line
per reported level change, in `/var/lib/upower/history-charge-<model>-<serial>.dat`
— and never surfaces it over D-Bus. That is enough to fit the rate ourselves,
which is what `Model.estimateSecondsRemaining` does: take the trailing run of
samples matching the current charge state, least-squares the percentage against
time, extrapolate to 100% or 0%.

Least squares rather than first-to-last because the readings bounce a few points
either way as voltage sags under click load and recovers. On ~7 days of real
data the fit gave −4.43 %/day against a −4.47 %/day endpoint rate, and the
estimate is prefixed with `~` so it never reads as a measurement. Whatever the
device itself reports always wins when it reports anything.

The estimate is deliberately withheld rather than guessed. It needs at least 3
samples spanning 20 minutes in the current run, a slope whose sign matches the
state, and a result under 60 days — otherwise the row dashes. A run in the
opposite direction means the state just flipped and there is genuinely no data
for the new one yet.

The serial is only known after the device is resolved, so the D-Bus lookup and
the log read happen in the same script. UPower renames the history file when the
reported model string changes and leaves the old one behind — one G Pro here has
both `history-charge-G_Pro_Wireless_Gaming_Mouse-<serial>.dat` and
`history-charge-Logitech_G_Pro-<serial>.dat` — so the glob takes every file
carrying the serial and `parseHistory` merges and de-duplicates by timestamp.
The glob is anchored on the serial (not wrapped in wildcards) and serials under
four characters are refused, so a device reporting `0` cannot swallow another
device's log.

Two ways this row legitimately stays empty, neither of them a bug: the device
reports no serial, or `/var/lib/upower` is not readable — UPower writes some
history files `0640 root:root`. Everything else in the panel still works.

**Known weak spot: charging.** Some mice do not re-report their level while on
the cable at all. Observed directly on a G Pro Wireless:

```
1786077317   23.000  charging        05:35:17   ← went on the cable
1786082170  100.000  fully-charged   06:56:10   ← unplugged and replugged
```

81 minutes, no samples. The 23% was frozen at the moment it was plugged in;
unplugging re-enumerated the device (`hidpp_battery_1` became
`hidpp_battery_3`) and forced a fresh read that returned the truth. Discharge —
the direction that actually tells you when to plug in — has days of clean data
behind it.

Two guards fall out of that:

- `currentRun` breaks the run at any step of 25 percentage points or more.
  A stale level that snaps to the truth is a reporting artefact, and a fit
  across it would be nonsense. Real discharge steps at most 5 points between
  consecutive samples, so the guard never touches good data.
- The estimate is only computed while the device is actually Charging or
  Discharging. Sitting at FullyCharged on the cable is neither direction, and
  without the check the discharge history would happily project a "time left"
  for a mouse that is not discharging. That state shows `Full` instead.

Device renumbering on replug is survivable because the history glob is keyed on
the **serial**, which is stable, not on the native path, which is not.

## Low battery

At or below `lowThreshold` (default 20%, discharging only) the bar glyph and the
panel's big reading take the theme's urgent colour. The glyph rides
`WidgetButton.active`, which is that component's existing urgent-colour channel,
so it tracks theme changes with no colour handling of its own.

## The bar pill

A `WidgetButton` hosting a `Row` of an `OpticalGlyph` and a `Text`, rather than
`BarIconButton`'s single string. One string would drag the nerd-font glyph down
to text size; two items keep it on its own optical sizing (`Style.bar.iconFont`)
beside a body-sized reading. The percentage sits to the **right** of the glyph.

The horizontal padding is `iconSlot - iconCanvas`, which holds the icon-only
pill at exactly the 27px slot `BarIconButton` gives it — so turning the
percentage off returns the bar to the spacing it had before, to the pixel.

The plugin is built on the same base classes `omarchy.power` uses (`Ui/Panel`,
`BarIconButton`, `KeyboardPanel`) so it sits on the bar as a peer rather than a
bolt-on, and it borrows that plugin's battery glyph ramp verbatim.

## Two traps worth remembering

**`UPower.devices.values` is not a JS Array.** It is a QML sequence type:
`Array.isArray()` on it returns `false`, while `.length` and `[i]` both work.
`Model.pickDevice` therefore walks it by length rather than guarding with
`Array.isArray`, which in the first cut silently treated every device list as
empty — the widget registered, loaded, and rendered nothing, with no warning in
the log.

**Enabling a plugin needs a shell restart; editing one does not.** After
`omarchy plugin enable io.github.twoscott.mouse-battery`,
`omarchy-shell shell rescanPlugins` registers the widget but the bar slot never
instantiates it — `Component.onCompleted` does not fire until
`omarchy restart shell`. Subsequent edits to `Panel.qml` / `Model.js`
hot-reload normally.

## Notes

- `showPercentage` persists through `shell.updateEntryInline`, which rebuilds
  every widget in the bar section. That is invisible here because the reading
  comes from a UPower singleton that has data on the first frame.
- `Model.js` is plain side-effect-free JS with a `module.exports` tail, so the
  matching and formatting rules can be exercised with `node` without a running
  shell.

## License

MIT.
