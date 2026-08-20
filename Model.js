// Pure helpers for io.github.twoscott.mouse-battery. Everything here is side-effect free so
// the device-matching and formatting rules can be reasoned about (and poked at
// with node) without a running shell.

// Model wording that marks a UPower peripheral as a pointing device. Vendors
// spell their mice a dozen ways and not all of them contain "mouse", so the
// obvious hint is backed by product-line names that are unambiguously mice.
// Bare vendor names are deliberately absent: "razer" would match a BlackWidow
// keyboard as happily as a Viper.
var MOUSE_HINTS = [
  // Generic
  "mouse", "mice", "trackball", "trackman",
  // Logitech
  "mx master", "mx anywhere", "mx ergo", "mx vertical", "anywhere", "lift",
  "pebble", "superlight", "triathlon", "marathon",
  "g pro", "g102", "g203", "g304", "g305", "g309", "g402", "g403", "g502",
  "g603", "g604", "g703", "g903",
  // Razer
  "deathadder", "viper", "basilisk", "naga", "orochi", "lancehead", "mamba",
  "atheris", "pro click", "cobra",
  // SteelSeries
  "aerox", "rival", "sensei", "prime wireless",
  // Corsair
  "harpoon", "dark core", "katar", "ironclaw", "nightsword", "sabre", "m65",
  "scimitar",
  // Glorious, Pulsar, and the wider superlight crowd
  "model o", "model d", "model i", "xlite", "lamzu", "vaxee", "zowie",
  "endgame", "attack shark", "ninjutso"
]

// Logitech's M-series (M705, M720, M590...) are mice; their keyboards are the
// K-series, so the digit pattern is safe to match on its own.
var MOUSE_MODEL_PATTERN = /\bm\d{3}\b/

// Battery glyph ramps, borrowed verbatim from omarchy.power so this widget
// reads as part of the same bar rather than a bolt-on. Index is tenths of
// charge, so the glyph itself carries the approximate level.
var CHARGING_ICONS = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var DEFAULT_ICONS = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

function lower(value) {
  return String(value === undefined || value === null ? "" : value).toLowerCase()
}

// Model name and kernel path together — a Logitech unifying mouse identifies
// itself through one or the other depending on the driver in play.
function haystack(device) {
  var d = device || {}
  return lower(d.model) + " " + lower(d.nativePath)
}

function matchesMouseHint(hay) {
  for (var i = 0; i < MOUSE_HINTS.length; i++) {
    if (hay.indexOf(MOUSE_HINTS[i]) >= 0) return true
  }
  return MOUSE_MODEL_PATTERN.test(hay)
}

// Peripherals only. `powerSupply` is true for the machine's own battery and for
// AC line power, which are omarchy.power's job, not ours.
//
// Device *type* is deliberately not filtered here. UPower cannot classify every
// peripheral it sees: a Bluetooth mouse whose appearance byte says nothing
// arrives as Type=Unknown, and a plain HID battery node can arrive as
// Type=Battery with scope=Device. Either is still a mouse if the user says so.
// Type is weighed in deviceScore instead, where auto-detection can demand
// evidence and an explicit `match` can waive it.
function isPeripheral(device, types) {
  var d = device || {}
  var t = types || {}
  if (!d.isPresent) return false
  if (d.powerSupply) return false
  if (t.LinePower !== undefined && d.type === t.LinePower) return false
  return true
}

// Which type readings auto-detection is willing to accept. Mouse is UPower
// saying so; Unknown and a bare Battery on a scope=Device node are UPower
// saying it does not know, which is the shape a Bluetooth mouse with no
// appearance byte arrives in. Anything else — Keyboard, Headset, GamingInput —
// is a positive claim that the device is something other than a mouse, and only
// the model wording may overrule it. This is what keeps a hid++ keyboard or a
// wireless headset out: they ride the same transport as the mouse, so `hidpp`
// on its own must not be allowed to vouch for them.
function typeAllowsAutoDetect(device, types) {
  var t = types || {}
  var type = device ? device.type : undefined
  if (type === undefined) return true
  if (t.Mouse !== undefined && type === t.Mouse) return true
  if (t.Unknown !== undefined && type === t.Unknown) return true
  if (t.Battery !== undefined && type === t.Battery) return true
  if (t.BluetoothGeneric !== undefined && type === t.BluetoothGeneric) return true
  return false
}

// How strongly a device looks like the mouse we want. Zero means "not a
// candidate" — never picked, even if it is the only device on the bus.
//
// Device type alone cannot be trusted: UPower's hid++ backend has been seen
// reporting a G Pro Wireless with Type=Keyboard. The transport (`hidpp_*`) and
// the model wording are the signals that hold, and a genuine Mouse type is a
// bonus on top rather than a gate.
function deviceScore(device, match, types) {
  if (!isPeripheral(device, types)) return 0

  var hay = haystack(device)

  // An explicit `match` setting is the user speaking. Honour it literally and
  // skip every heuristic below — including the type evidence, which is exactly
  // what a mouse UPower could not classify needs waived.
  if (match) return hay.indexOf(lower(match)) >= 0 ? 100 : 0

  var t = types || {}
  var mouseType = t.Mouse !== undefined && device.type === t.Mouse
  var hidpp = hay.indexOf("hidpp") >= 0
  var hinted = matchesMouseHint(hay)

  // A device UPower has typed as something else entirely needs its model to say
  // otherwise before it is even considered.
  if (!hinted && !typeAllowsAutoDetect(device, types)) return 0

  // Auto-detection needs positive evidence. Without it, any unclassified
  // peripheral on the bus would be picked as "the mouse" for want of a rival.
  if (!mouseType && !hidpp && !hinted) return 0

  var score = 0
  if (mouseType) score += 4
  if (hidpp) score += 3
  if (hinted) score += 2
  return score
}

// Ordering for equal scores, so a receiver carrying both a mouse and a keyboard
// resolves the same way on every start rather than by whichever device UPower
// happened to enumerate first. A genuine Mouse type wins; failing that the
// lowest native path, which is arbitrary but stable.
function tieBreakBetter(candidate, incumbent, types) {
  if (!incumbent) return true
  var t = types || {}
  if (t.Mouse !== undefined) {
    var a = !!candidate && candidate.type === t.Mouse
    var b = incumbent.type === t.Mouse
    if (a !== b) return a
  }
  return lower(candidate && candidate.nativePath) < lower(incumbent.nativePath)
}

// `UPower.devices.values` is a QML sequence type, not a JS Array —
// `Array.isArray` on it returns false. Index by length so both that and a
// plain array (what the node checks pass in) walk the same path.
function pickDevice(devices, match, types) {
  var list = devices
  var count = list && typeof list.length === "number" ? list.length : 0
  var best = null
  var bestScore = 0
  for (var i = 0; i < count; i++) {
    var score = deviceScore(list[i], match, types)
    if (score <= 0) continue
    if (score > bestScore || (score === bestScore && tieBreakBetter(list[i], best, types))) {
      bestScore = score
      best = list[i]
    }
  }
  return best
}

// 0..1, matching how Quickshell normalises UPowerDevice.percentage.
function fractionOf(device) {
  var d = device || {}
  if (!d.isPresent) return 0
  var value = Number(d.percentage)
  if (!isFinite(value)) return 0
  return Math.max(0, Math.min(1, value))
}

function batteryIcon(fraction, charging, full) {
  if (full) return "󰂅"
  var index = Math.max(0, Math.min(9, Math.floor(fraction * 10)))
  return charging ? CHARGING_ICONS[index] : DEFAULT_ICONS[index]
}

function stateLabel(device, states) {
  var d = device || {}
  var s = states || {}
  if (!d || !d.isPresent) return "Not connected"
  if (d.state === s.Charging) return "Charging"
  if (d.state === s.Discharging) return "Discharging"
  if (d.state === s.FullyCharged) return "Fully charged"
  if (d.state === s.Empty) return "Empty"
  if (d.state === s.PendingCharge) return "Pending charge"
  if (d.state === s.PendingDischarge) return "Pending discharge"
  return "Idle"
}

// UPower reports timeToEmpty / timeToFull in seconds, and reports 0 when it has
// no estimate — which is the normal case for hid++ peripherals, since they
// publish a level with no rate behind it. A mouse runs for days, so drop to
// days-and-hours past two days rather than printing "110h 24m".
function formatDuration(seconds) {
  var total = Math.round(Number(seconds) || 0)
  if (total <= 0) return ""

  if (total >= 48 * 3600) {
    var days = Math.floor(total / 86400)
    var leftoverHours = Math.round((total % 86400) / 3600)
    if (leftoverHours === 24) {
      days += 1
      leftoverHours = 0
    }
    return leftoverHours > 0 ? days + "d " + leftoverHours + "h" : days + "d"
  }

  var hours = Math.floor(total / 3600)
  var minutes = Math.round((total % 3600) / 60)
  if (minutes === 60) {
    hours += 1
    minutes = 0
  }
  if (hours <= 0) return minutes + "m"
  return hours + "h " + minutes + "m"
}

// ---------------------------------------------------------------- estimation
//
// UPower cannot give this hardware a time estimate (no energy or rate on the
// hid++ power_supply node), but it *does* keep a charge log per device in
// /var/lib/upower/history-charge-<model>-<serial>.dat, one
// "<epoch> <percentage> <state>" line per reported change. That log is enough
// to fit a rate ourselves.

// Samples with state "unknown" are UPower's segment markers, always paired with
// a 0.000 reading. Dropping them is what makes the rest a clean series.
function parseHistory(raw) {
  var out = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length < 3) continue
    var t = Number(parts[0])
    var pct = Number(parts[1])
    var state = parts[2]
    if (!isFinite(t) || t <= 0 || !isFinite(pct) || pct <= 0) continue
    if (state !== "charging" && state !== "discharging") continue
    out.push({ t: t, pct: pct, state: state })
  }
  out.sort(function(a, b) { return a.t - b.t })

  // The same device can appear under more than one history file (UPower renames
  // them when the reported model string changes), so merge and de-duplicate by
  // timestamp rather than trusting one file.
  var deduped = []
  for (var j = 0; j < out.length; j++) {
    if (j > 0 && out[j].t === out[j - 1].t) continue
    deduped.push(out[j])
  }
  return deduped
}

// The trailing block of samples that share the state the device is in right
// now. A run in the other direction means the state just flipped and we have no
// data for the new one yet — which is a real "cannot know", not a zero.
function currentRun(samples, charging, nowSeconds, maxAgeSeconds, maxJump) {
  var want = charging ? "charging" : "discharging"
  var list = samples || []
  var cutoff = (nowSeconds || 0) - (maxAgeSeconds || 14 * 86400)
  var jumpLimit = maxJump || 25
  var run = []
  for (var i = list.length - 1; i >= 0; i--) {
    if (list[i].state !== want) break
    if (list[i].t < cutoff) break
    // A step this large is a reporting artefact, not a trend. The hid++ driver
    // can hold a stale level for an entire charge and then snap to the truth
    // when the device is replugged — observed on this mouse as 23% at 05:35
    // followed by 100% at 06:56 with nothing in between, because unplugging
    // re-enumerated it (hidpp_battery_1 became hidpp_battery_3) and forced a
    // fresh read. Samples before such a step describe a different reality, so
    // the run starts after it.
    if (run.length > 0 && Math.abs(run[0].pct - list[i].pct) >= jumpLimit) break
    run.unshift(list[i])
  }
  return run
}

// Least squares over percentage against time. The readings bounce a few points
// either way — voltage sags under click load and recovers — so a two-point
// slope is far too noisy; the fit averages that out.
function fitSlopePerSecond(run) {
  var n = run.length
  if (n < 2) return 0

  var sumT = 0, sumP = 0
  for (var i = 0; i < n; i++) {
    sumT += run[i].t
    sumP += run[i].pct
  }
  var meanT = sumT / n
  var meanP = sumP / n

  var num = 0, den = 0
  for (var j = 0; j < n; j++) {
    var dt = run[j].t - meanT
    num += dt * (run[j].pct - meanP)
    den += dt * dt
  }
  if (den === 0) return 0
  return num / den
}

// Seconds until full (charging) or empty (discharging), or 0 when the history
// cannot support an estimate. Deliberately conservative: it would rather show
// nothing than a number the data does not justify.
function estimateSecondsRemaining(samples, charging, currentPct, nowSeconds, options) {
  var opts = options || {}
  var minSamples = opts.minSamples || 3
  var minSpanSeconds = opts.minSpanSeconds || 20 * 60
  var maxResultSeconds = opts.maxResultSeconds || 60 * 86400

  var run = currentRun(samples, charging, nowSeconds, opts.maxAgeSeconds, opts.maxJump)
  if (run.length < minSamples) return 0
  if (run[run.length - 1].t - run[0].t < minSpanSeconds) return 0

  var slope = fitSlopePerSecond(run)
  // Wrong-signed slope means the fit is measuring noise, not a trend.
  if (charging && slope <= 0) return 0
  if (!charging && slope >= 0) return 0

  var target = charging ? 100 : 0
  var remaining = (target - currentPct) / slope
  if (!isFinite(remaining) || remaining <= 0) return 0
  if (remaining > maxResultSeconds) return 0
  return remaining
}

// `upower -i` prints two-space-indented "key: value" lines. Values can contain
// colons (timestamps do), so only the first colon separates. Section headers
// such as "keyboard" have no colon and are skipped.
function parseUpowerInfo(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var idx = line.indexOf(":")
    if (idx <= 0) continue
    var key = line.substring(0, idx).trim()
    if (!/^[a-z][a-z0-9-]*$/.test(key)) continue
    out[key] = line.substring(idx + 1).trim()
  }
  return out
}

// The `updated` line ends with a parenthesised relative age that is already
// phrased the way we want to show it:
//   updated:  Fri 07 Aug 2026 05:40:17 AM BST (8 seconds ago)
function updatedAgo(value) {
  var text = String(value || "")
  var open = text.lastIndexOf("(")
  var close = text.lastIndexOf(")")
  if (open < 0 || close <= open) return ""
  return text.substring(open + 1, close).trim()
}

// Panel.qml renders its own strings as PlainText, but the bar tooltip is drawn
// by the shell's PanelToolTip, whose Text is left at the default AutoText — so
// a model string of `<img src="http://host/x.png">` would still reach a
// rich-text parser through that one sink, which this plugin cannot pin from
// here. Strip the characters that can open markup (`<` for a tag, `&` for an
// entity — either is enough for mightBeRichText to say yes — and `>` with
// them so no half-tag is left behind) and fold the whitespace, which also
// keeps a device from spilling the tooltip over several lines with a newline
// in its name. No real mouse's model string contains any of them.
function plainText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[<>&]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
}

function shortDeviceName(device) {
  var d = device || {}
  var model = plainText(d.model)
  if (model) return model
  var native = plainText(d.nativePath)
  return native || "Wireless mouse"
}

if (typeof module !== "undefined") {
  module.exports = {
    MOUSE_HINTS: MOUSE_HINTS,
    matchesMouseHint: matchesMouseHint,
    isPeripheral: isPeripheral,
    typeAllowsAutoDetect: typeAllowsAutoDetect,
    tieBreakBetter: tieBreakBetter,
    deviceScore: deviceScore,
    pickDevice: pickDevice,
    fractionOf: fractionOf,
    batteryIcon: batteryIcon,
    stateLabel: stateLabel,
    formatDuration: formatDuration,
    parseHistory: parseHistory,
    currentRun: currentRun,
    fitSlopePerSecond: fitSlopePerSecond,
    estimateSecondsRemaining: estimateSecondsRemaining,
    parseUpowerInfo: parseUpowerInfo,
    updatedAgo: updatedAgo,
    plainText: plainText,
    shortDeviceName: shortDeviceName
  }
}
