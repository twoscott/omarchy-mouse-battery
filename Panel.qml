import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Wireless mouse battery: one bar glyph, one panel.
//
// Shaped after omarchy.power — same Panel base, same BarIconButton +
// KeyboardPanel pairing, same battery glyph ramp — but pointed at a UPower
// *peripheral* instead of the machine's own battery, so the two can sit side by
// side on the bar without reading as duplicates.
//
// The bar shows the glyph alone: its ten fill levels are the approximate
// reading. The exact percentage lives in the panel.
Panel {
  id: root
  moduleName: "io.github.twoscott.mouse-battery"
  ipcTarget: "io.github.twoscott.mouse-battery"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false

  // ---------------------------------------------------------------- settings

  // Substring matched (case-insensitively) against the device model and kernel
  // path. Empty means auto-detect; see Model.deviceScore.
  readonly property string matchSetting: String(setting("match", ""))
  // Percentage at or below which the glyph turns urgent.
  readonly property int lowThreshold: Number(setting("lowThreshold", 20))
  // Off by default — the request was an icon-only pill. Right-click toggles it.
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // A mouse that has been switched off disappears from UPower entirely. Hiding
  // the widget then is the honest default; set false to keep a dimmed slot.
  readonly property bool hideWhenAbsent: setting("hideWhenAbsent", true) !== false

  // ----------------------------------------------------------------- device

  function deviceTypes() {
    return {
      Unknown: UPowerDeviceType.Unknown,
      LinePower: UPowerDeviceType.LinePower,
      Battery: UPowerDeviceType.Battery,
      Mouse: UPowerDeviceType.Mouse,
      BluetoothGeneric: UPowerDeviceType.BluetoothGeneric
    }
  }

  function deviceStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      Empty: UPowerDeviceState.Empty,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge,
      PendingDischarge: UPowerDeviceState.PendingDischarge
    }
  }

  readonly property var upowerDevices: UPower.devices ? UPower.devices.values : []
  readonly property var device: Model.pickDevice(upowerDevices, matchSetting, deviceTypes())
  readonly property bool hasDevice: !!device && device.isPresent

  readonly property real batteryFraction: Model.fractionOf(device)
  readonly property int batteryPercent: Math.round(batteryFraction * 100)
  readonly property string deviceName: Model.shortDeviceName(device)
  readonly property string nativePath: hasDevice ? String(device.nativePath || "") : ""

  readonly property bool charging: hasDevice && device.state === UPowerDeviceState.Charging
  readonly property bool fullyCharged: hasDevice && (device.state === UPowerDeviceState.FullyCharged || batteryFraction >= 1)
  readonly property bool low: hasDevice && !charging && batteryPercent <= lowThreshold

  readonly property string statusText: Model.stateLabel(device, deviceStates())
  readonly property string batteryGlyph: Model.batteryIcon(batteryFraction, charging, fullyCharged)

  // Remaining time. UPower derives this as energy-needed ÷ energy-rate and the
  // hid++ driver exports neither — its power_supply node carries `capacity`,
  // `status` and `voltage_now` and nothing else — so both timings come back 0
  // on mouse hardware and we fit the rate ourselves from UPower's charge log.
  //
  // Whatever the device reports wins when it reports anything; the fit is the
  // fallback and is prefixed with a tilde so an estimate never reads as a
  // measurement.
  readonly property real reportedRemainingSeconds: {
    if (!hasDevice) return 0
    var value = Number(charging ? device.timeToFull : device.timeToEmpty)
    return isFinite(value) && value > 0 ? value : 0
  }
  // Only extrapolate while charge is actually moving. Sitting at FullyCharged
  // on the cable is neither direction, and without this the discharge history
  // would happily project a "time left" for a mouse that is not discharging.
  readonly property bool flowing: hasDevice
    && (device.state === UPowerDeviceState.Charging || device.state === UPowerDeviceState.Discharging)

  readonly property real estimatedRemainingSeconds: {
    if (!hasDevice || !flowing || reportedRemainingSeconds > 0) return 0
    return Model.estimateSecondsRemaining(history, charging, batteryPercent, Math.floor(Date.now() / 1000))
  }
  readonly property string remainingLabel: charging || fullyCharged ? "Time to full" : "Time left"
  readonly property string remainingValue: {
    if (fullyCharged && !charging) return "Full"
    if (reportedRemainingSeconds > 0) return Model.formatDuration(reportedRemainingSeconds)
    var estimate = Model.formatDuration(estimatedRemainingSeconds)
    return estimate === "" ? "" : "~" + estimate
  }

  readonly property color accentColor: {
    var base = root.bar ? root.bar.foreground : Color.foreground
    if (!root.low) return base
    return root.bar ? root.bar.urgent : Color.urgent
  }

  // ------------------------------------------------- out-of-band supplements
  //
  // The UPower service gives us everything that changes on its own (level,
  // state) over D-Bus, push-based. Two things it does not give us:
  //
  //   `updated`  — *when the device last reported*, which for a wireless
  //                peripheral is the difference between "23%" and "23% as of
  //                two hours ago, and it has been asleep since". Exists only on
  //                the `upower -i` CLI output.
  //
  //   history    — the per-device charge log under /var/lib/upower. UPower
  //                writes a line per reported level change and never surfaces
  //                it over D-Bus, but it is what makes a rate — and therefore a
  //                time estimate — recoverable on hardware that reports none.
  //
  // One Process covers both, polled while the panel is open.

  property var extraInfo: ({})
  property var history: []
  readonly property string lastReported: Model.updatedAgo(extraInfo["updated"])
  readonly property string serialNumber: String(extraInfo["serial"] || "")

  function refresh() {
    if (!hasDevice || nativePath === "") return
    if (!infoProc.running) infoProc.running = true
  }

  function applyInfo(raw) {
    var text = String(raw || "")
    var split = text.indexOf(historySentinel)
    var infoText = split >= 0 ? text.substring(0, split) : text
    var historyText = split >= 0 ? text.substring(split + historySentinel.length) : ""

    var next = Model.parseUpowerInfo(infoText)
    // Keep the last known good block if a poll comes back empty — happens while
    // the receiver re-enumerates. Avoids the rows collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    extraInfo = next
    history = Model.parseHistory(historyText)
  }

  readonly property string historySentinel: "--history--"

  Process {
    id: infoProc
    // `upower -e` prints D-Bus paths; the mapping from a path back to a kernel
    // native-path is not a stable string transform (this mouse is
    // battery_hidpp_battery_1), so resolve it by reading each device rather
    // than by constructing the path.
    //
    // The history filename embeds the serial, and the serial is only known
    // once the device has been resolved — so the lookup and the log read have
    // to happen in the same script. UPower renames the file when the reported
    // model string changes and leaves the old one behind, so the glob takes
    // every file carrying this serial and Model.parseHistory merges them.
    command: ["bash", "-c",
      "want=\"$1\"; info=\"\"; " +
      "for p in $(upower -e); do " +
        "got=$(upower -i \"$p\" 2>/dev/null); " +
        "np=$(echo \"$got\" | sed -n \"s/^ *native-path: *//p\" | head -1); " +
        "if [ \"$np\" = \"$want\" ]; then info=\"$got\"; break; fi; " +
      "done; " +
      "[ -n \"$info\" ] || exit 0; " +
      "echo \"$info\"; " +
      "echo \"$2\"; " +
      "serial=$(echo \"$info\" | sed -n \"s/^ *serial: *//p\" | head -1); " +
      // A serial shorter than this is not identifying anything — some devices
      // report \"0\" or \"1\" — and would glob onto every log in the directory.
      "[ ${#serial} -ge 4 ] || exit 0; " +
      // Anchored on the serial rather than wrapped in wildcards: the filename
      // is history-charge-<model>-<serial>.dat, so a trailing wildcard would
      // let a short serial swallow another device's log.
      "cat /var/lib/upower/history-charge-*\"$serial\".dat 2>/dev/null | tail -n 2000",
      "_", root.nativePath, root.historySentinel]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyInfo(text) }
  }

  Timer {
    interval: 15000
    running: root.opened && root.hasDevice
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------------------- glue

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "io.github.twoscott.mouse-battery"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (!opened) return
    if (!hasDevice) {
      close()
      return
    }
    refresh()
  }

  onHasDeviceChanged: if (!hasDevice) close()

  visible: hasDevice || !hideWhenAbsent
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  readonly property bool vertical: bar ? bar.vertical : false

  // A vertical bar has no room for a reading, so the pill stays icon-only
  // there — matching every other status widget in that orientation.
  readonly property string percentText: showPercentage && !vertical ? batteryPercent + "%" : ""

  // With the percentage shown the button paints wider than an icon, so the
  // open-panel mark takes the painted width instead of the icon-sized fraction
  // of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: percentText !== "" ? content.implicitWidth : 0

  // ---------------------------------------------------------------- bar pill
  //
  // A Row of an OpticalGlyph and a Text rather than `BarIconButton`'s single
  // string, for the reason local.weather forks upstream for: one string drags
  // the nerd-font glyph down to text size, where it wants its own optical
  // sizing (Style.bar.iconFont) beside a body-sized reading.
  //
  // The padding is `iconSlot - iconCanvas` rather than local.weather's
  // `statusSlot - iconCanvas`, which keeps the icon-only pill at exactly the
  // 27px slot BarIconButton gave it — so turning the percentage off returns the
  // bar to the spacing it had before, to the pixel.

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.batteryGlyph !== ""
    fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + Style.bar.iconSlot - Style.bar.iconCanvas)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    dimmed: !root.hasDevice
    // `active` is WidgetButton's urgent-color channel; a low mouse battery is
    // exactly what it is for.
    active: root.low
    tooltipText: root.hasDevice
      ? root.deviceName + " · " + root.batteryPercent + "%"
      : "Mouse not connected"
    onPressed: function(b) {
      if (!root.hasDevice) return
      if (b === Qt.RightButton) root.togglePercentage()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: root.percentText === "" ? 0 : Style.space(2)

      OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.batteryGlyph
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.percentText !== ""
        text: root.percentText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.hasDevice
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: mouse glyph · name/status · exact percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            text: "󰍽"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.deviceName
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          // The exact reading the bar glyph only approximates.
          Text {
            id: heroPercent
            text: root.hasDevice ? root.batteryPercent + "%" : "—"
            color: root.accentColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Charge bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.accentColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Detail ----------
        Row {
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            // For a wireless peripheral the age of the reading matters as much
            // as the reading: a mouse asleep in a drawer keeps reporting its
            // last known level forever.
            InfoPair { label: "Reported"; value: root.lastReported || "—" }
            // Dashed only until the current charge or discharge run has enough
            // samples behind it to fit a rate — a transient state, not the
            // permanent blank the device's own zeroed timings would give.
            InfoPair { label: root.remainingLabel; value: root.remainingValue || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Device"; value: root.nativePath || "—" }
            InfoPair { label: "Serial"; value: root.serialNumber || "—" }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
