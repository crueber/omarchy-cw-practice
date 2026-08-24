import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// CW Practice panel: play/pause, delayed-reveal history, and settings
// (speed, delay, sidetone, volume, word gaps, character selection).
// Audio comes from a long-running cw_player.py child process that sends
// random characters with PARIS timing and reports each one back on stdout
// as its audio finishes playing; QML queues the reveal by the delay.
Panel {
  id: root
  moduleName: "crueber.cwpractice"
  ipcTarget: "crueber.cwpractice"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() { openedFromHotkey = false; root.controller.show() }
  function openFromHotkey() { openedFromHotkey = true; root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.openFromHotkey() }

  readonly property color fg: bar ? bar.foreground : Color.foreground

  // Opt-in gate for state-changing IPC (see BarWidget.qml). Default off.
  // `omarchy bar set` stores inline settings as strings, so accept both
  // boolean true and the string "true".
  readonly property bool ipcControlAllowed: {
    var v = setting("allowIpcControl", false)
    return v === true || v === "true"
  }
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family

  // ---- persisted state ----
  property int wpm: Model.DEFAULT_STATE.wpm
  property int delayMs: Model.DEFAULT_STATE.delayMs
  property int toneHz: Model.DEFAULT_STATE.toneHz
  property int volume: Model.DEFAULT_STATE.volume
  property bool wordGaps: Model.DEFAULT_STATE.wordGaps
  property var enabledChars: Model.DEFAULT_STATE.chars.slice()

  // ---- live slider values (committed on release) ----
  property int liveWpm: wpm
  property int liveDelayMs: delayMs
  property int liveToneHz: toneHz
  property int liveVolume: volume

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/cwpractice"
  readonly property string stateFile: stateDir + "/state.json"

  // ---- player ----
  property bool wantRunning: false
  property bool stopRequested: false
  property string errorMessage: ""
  property string playerError: ""

  // ---- history ----
  property string historyText: ""
  property var revealQueue: []

  function isEnabled(ch) { return enabledChars.indexOf(ch) !== -1 }

  function toggleChar(ch) {
    var out = []
    var found = false
    for (var i = 0; i < enabledChars.length; i++) {
      if (enabledChars[i] === ch) found = true
      else out.push(enabledChars[i])
    }
    if (!found) out.push(ch)
    enabledChars = out
    saveState()
    pushPool()
  }

  function setGroupEnabled(chars, enabled) {
    var set = {}
    for (var i = 0; i < chars.length; i++) set[chars[i]] = true
    var out = []
    if (enabled) {
      for (var j = 0; j < Model.ALL_CHARS.length; j++) {
        var c = Model.ALL_CHARS[j]
        if (set[c] || isEnabled(c)) out.push(c)
      }
    } else {
      for (var k = 0; k < enabledChars.length; k++)
        if (!set[enabledChars[k]]) out.push(enabledChars[k])
    }
    enabledChars = out
    saveState()
    pushPool()
  }

  function clearHistory() {
    historyText = ""
    revealQueue = []
  }

  function buildCommand() {
    var cmd = ["python3", Model.assetPath(Qt.resolvedUrl("cw_player.py")),
      "--wpm", String(wpm), "--tone", String(toneHz), "--volume", String(volume),
      "--pool", enabledChars.join("")]
    if (wordGaps) cmd.push("--word-gaps")
    return cmd
  }

  function launchPlayer() {
    playerError = ""
    errorMessage = ""
    player.command = buildCommand()
    player.running = true
  }

  function play() {
    if (wantRunning) return
    if (enabledChars.length === 0) { errorMessage = "Select at least one character"; return }
    wantRunning = true
    stopRequested = false
    if (player.running) {
      stopRequested = true
      player.running = false
    } else {
      launchPlayer()
    }
  }

  function pause() {
    if (!wantRunning) return
    wantRunning = false
    stopRequested = true
    player.running = false
  }

  function toggleRun() { wantRunning ? pause() : play() }

  // Live settings: while a run is active, changes are pushed to the player
  // over stdin and applied at the next character boundary — no restart, no
  // gap in the audio. When idle the persisted state is picked up at start.
  function pushSetting(key, value) {
    if (player.running) player.write("SET " + key + "=" + value + "\n")
  }

  function pushPool() { pushSetting("pool", enabledChars.join("")) }

  // Shared entry point for the settings controls and the IPC `set`
  // function. Validated, persisted, and (when running) applied live.
  // Returns true when the key/value pair was valid.
  function applySetting(key, value) {
    var n = Number(value)
    if (key === "wpm") {
      wpm = Model.clampInt(n, Model.MIN_WPM, Model.MAX_WPM, wpm)
      liveWpm = wpm
      pushSetting("wpm", wpm)
    } else if (key === "delay") {
      // Snap to the documented 0.5 s steps — PanelSlider only applies
      // `step` to wheel events, not drags.
      delayMs = Math.round(Model.clampInt(n, 0, Model.MAX_DELAY, delayMs)
        / Model.DELAY_STEP) * Model.DELAY_STEP
      liveDelayMs = delayMs
    } else if (key === "tone") {
      toneHz = Model.clampInt(n, Model.MIN_TONE, Model.MAX_TONE, toneHz)
      liveToneHz = toneHz
      pushSetting("tone", toneHz)
    } else if (key === "volume") {
      volume = Model.clampInt(n, Model.MIN_VOLUME, Model.MAX_VOLUME, volume)
      liveVolume = volume
      pushSetting("volume", volume)
    } else if (key === "word-gaps") {
      wordGaps = value === "1" || value === "true"
      pushSetting("word-gaps", wordGaps ? "1" : "0")
    } else if (key === "pool") {
      enabledChars = Model.sanitizeChars(String(value).split(""))
      pushPool()
      // The player rejects an empty pool and keeps its previous one; make
      // that divergence visible instead of silently sending stale audio.
      if (player.running && enabledChars.length === 0)
        errorMessage = "No characters selected — still sending the previous set"
      else if (enabledChars.length > 0)
        errorMessage = ""
    } else {
      return false
    }
    saveState()
    return true
  }

  function handlePlayerExit(code) {
    if (wantRunning && stopRequested) {
      stopRequested = false
      restartTimer.restart()
    } else if (wantRunning) {
      wantRunning = false
      stopRequested = false
      errorMessage = playerError !== "" ? playerError : "Audio process stopped (code " + code + ")"
    }
  }

  function handleCharLine(line) {
    var t = String(line).replace(/[\r\n]+$/, "")
    if (t === "") return
    var sp = t.charAt(t.length - 1) === " "
    var ch = sp ? t.slice(0, -1) : t
    if (ch === "") return
    revealQueue = revealQueue.concat([{ ch: ch, sp: sp, due: Date.now() + delayMs }])
  }

  function flushReveal() {
    var now = Date.now()
    var appended = ""
    var remaining = []
    for (var i = 0; i < revealQueue.length; i++) {
      var e = revealQueue[i]
      if (e.due <= now) appended += e.ch + (e.sp ? " " : "")
      else remaining.push(e)
    }
    if (appended !== "")
      historyText = (historyText + appended).slice(-Model.MAX_HISTORY)
    if (remaining.length !== revealQueue.length)
      revealQueue = remaining
  }

  function saveState() {
    var json = Model.serializeState({ wpm: wpm, delayMs: delayMs, toneHz: toneHz,
      volume: volume, wordGaps: wordGaps, chars: enabledChars })
    Util.execDetached("mkdir -p " + Util.shellQuote(stateDir)
      + " && t=$(mktemp -p " + Util.shellQuote(stateDir) + " .state.XXXXXX)"
      + " && printf '%s' " + Util.shellQuote(json) + " > \"$t\""
      + " && mv -f \"$t\" " + Util.shellQuote(stateFile))
  }

  function applyState(raw) {
    var s = Model.parseState(raw)
    root.wpm = s.wpm
    root.delayMs = s.delayMs
    root.toneHz = s.toneHz
    root.volume = s.volume
    root.wordGaps = s.wordGaps
    root.enabledChars = s.chars
    root.liveWpm = s.wpm
    root.liveDelayMs = s.delayMs
    root.liveToneHz = s.toneHz
    root.liveVolume = s.volume
  }

  // Open state.json once and read from that descriptor only. `dd` refuses
  // symlinks (iflag=nofollow), refuses to hang on a FIFO (iflag=nonblock),
  // and `timeout` is the hard deadline if an open/read ever stalls. The read
  // is capped at MAX_STATE_BYTES + 1 so an oversized or corrupt state.json
  // can't force unbounded allocation (FileView would read the whole file
  // first). Never stat/test the path and then cat it separately — the path
  // can change in between, redirecting or hanging the read.
  Process {
    id: stateLoader
    command: ["bash", "-c",
      'w="$1"; timeout ' + Model.STATE_READ_TIMEOUT_SECS
      + ' dd if="$w" iflag=nofollow,nonblock bs=' + (Model.MAX_STATE_BYTES + 1)
      + ' count=1 status=none 2>/dev/null',
      "_", root.stateFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        root.applyState(raw.length > Model.MAX_STATE_BYTES ? "" : raw)
      }
    }
    Component.onCompleted: running = true
  }

  Process {
    id: player
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleCharLine(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        var t = String(line).trim()
        if (t !== "") root.playerError = t
      }
    }
    onExited: function(code, status) { root.handlePlayerExit(code) }
  }

  Timer {
    id: restartTimer
    interval: 250
    property int attempts: 0
    onTriggered: {
      if (root.wantRunning && !root.player.running) {
        attempts = 0
        root.launchPlayer()
      } else if (root.wantRunning && attempts < 20) {
        // Old player hasn't fully exited yet — wait and retry (5 s total)
        // before giving up, so a stalled exit can't wedge the run silently.
        attempts += 1
        restart()
      } else if (root.wantRunning) {
        root.wantRunning = false
        root.errorMessage = "Could not restart audio — try again"
      }
    }
  }

  Timer {
    id: revealTimer
    interval: 100
    repeat: true
    running: root.revealQueue.length > 0
    onTriggered: root.flushReveal()
  }

  component SliderRow: Row {
    id: row
    property string label: ""
    property string valueText: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property real step: 1
    signal moved(real v)
    signal released(real v)
    width: parent.width
    spacing: Style.spacing.md

    Text {
      text: row.label
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFam
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    PanelSlider {
      id: slider
      width: parent.width - Style.space(52) - valueLabel.width - row.spacing * 2
      bar: root.bar
      value: row.value
      minimum: row.minimum
      maximum: row.maximum
      step: row.step
      integer: true
      onMoved: function(v) { row.moved(v) }
      onReleased: function(v) { row.released(v) }
    }

    Text {
      id: valueLabel
      text: row.valueText
      color: root.fg
      font.family: root.fontFam
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
      horizontalAlignment: Text.AlignRight
    }
  }

  component CharGroup: Column {
    id: grp
    property string title: ""
    property var chars: []
    width: parent.width
    spacing: Style.spacing.sm

    Row {
      width: parent.width
      spacing: Style.spacing.sm

      PanelSectionHeader {
        text: grp.title
        foreground: root.fg
        fontFamily: root.fontFam
        anchors.verticalCenter: parent.verticalCenter
      }

      Button {
        text: "All"
        fontSize: Style.font.bodySmall
        foreground: root.fg
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.setGroupEnabled(grp.chars, true)
      }

      Button {
        text: "None"
        fontSize: Style.font.bodySmall
        foreground: root.fg
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.setGroupEnabled(grp.chars, false)
      }
    }

    Grid {
      id: grid
      width: parent.width
      columns: 8
      spacing: Style.spacing.xs

      Repeater {
        model: grp.chars

        Button {
          required property string modelData
          width: (grid.width - grid.spacing * (grid.columns - 1)) / grid.columns
          text: modelData
          fontSize: Style.font.bodySmall
          foreground: root.fg
          selected: root.isEnabled(modelData)
          onClicked: root.toggleChar(modelData)
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.md

        // ===================== Practice =====================
        PanelSectionHeader { text: "CW Practice"; foreground: root.fg; fontFamily: root.fontFam }

        Button {
          width: parent.width
          text: root.wantRunning ? "Pause" : "Start practice"
          iconText: root.wantRunning ? "\uF03E4" : "\uF040A"
          foreground: root.fg
          fontFamily: root.fontFam
          fontSize: Style.font.subtitle
          onClicked: root.toggleRun()
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: root.errorMessage !== "" ? root.errorMessage
            : root.wantRunning ? "Sending at " + root.wpm + " WPM · " + root.toneHz + " Hz"
            : root.historyText !== "" ? "Paused"
            : "Pick characters, set a speed, and start copying"
          color: root.errorMessage !== "" ? Color.urgent : Qt.darker(root.fg, 1.4)
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
        }

        // ===================== History =====================
        Row {
          width: parent.width
          spacing: Style.spacing.sm

          PanelSectionHeader {
            text: "History"
            foreground: root.fg
            fontFamily: root.fontFam
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            text: "Clear"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.clearHistory()
          }
        }

        BorderSurface {
          width: parent.width
          radius: Style.cornerRadius
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
          implicitHeight: historyLabel.implicitHeight + Style.spacing.sm * 2

          Text {
            id: historyLabel
            anchors {
              fill: parent
              leftMargin: Style.spacing.rowPaddingX
              rightMargin: Style.spacing.rowPaddingX
              topMargin: Style.spacing.sm
              bottomMargin: Style.spacing.sm
            }
            text: root.historyText === "" ? "Received characters appear here"
              : root.historyText
            textFormat: Text.PlainText
            color: root.historyText === "" ? Qt.darker(root.fg, 1.6) : root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.subtitle
            wrapMode: Text.WrapAnywhere
            font.letterSpacing: 1
          }
        }

        PanelSeparator { foreground: root.fg }

        // ===================== Settings =====================
        PanelSectionHeader { text: "Settings"; foreground: root.fg; fontFamily: root.fontFam }

        SliderRow {
          label: "Speed"
          value: root.wpm
          minimum: Model.MIN_WPM
          maximum: Model.MAX_WPM
          step: 1
          valueText: root.liveWpm + " WPM"
          onMoved: function(v) { root.liveWpm = Math.round(v) }
          onReleased: function(v) { root.applySetting("wpm", Math.round(v)) }
        }

        SliderRow {
          label: "Delay"
          value: root.delayMs
          minimum: 0
          maximum: Model.MAX_DELAY
          step: Model.DELAY_STEP
          valueText: Model.delayLabel(root.liveDelayMs)
          onMoved: function(v) { root.delayMs = Math.round(v / Model.DELAY_STEP) * Model.DELAY_STEP; root.liveDelayMs = root.delayMs }
          onReleased: function(v) { root.applySetting("delay", Math.round(v)) }
        }

        SliderRow {
          label: "Tone"
          value: root.toneHz
          minimum: Model.MIN_TONE
          maximum: Model.MAX_TONE
          step: 10
          valueText: root.liveToneHz + " Hz"
          onMoved: function(v) { root.liveToneHz = Math.round(v / 10) * 10 }
          onReleased: function(v) { root.applySetting("tone", Math.round(v / 10) * 10) }
        }

        SliderRow {
          label: "Volume"
          value: root.volume
          minimum: Model.MIN_VOLUME
          maximum: Model.MAX_VOLUME
          step: 1
          valueText: root.liveVolume + "%"
          onMoved: function(v) { root.liveVolume = Math.round(v) }
          onReleased: function(v) { root.applySetting("volume", Math.round(v)) }
        }

        Toggle {
          width: parent.width
          label: "Word gaps"
          description: "Occasionally pause longer and add a space, like words in real text"
          checked: root.wordGaps
          foreground: root.fg
          fontFamily: root.fontFam
          onClicked: { root.applySetting("word-gaps", root.wordGaps ? "0" : "1") }
        }

        PanelSeparator { foreground: root.fg }

        // ===================== Characters =====================
        PanelSectionHeader { text: "Characters"; foreground: root.fg; fontFamily: root.fontFam }

        CharGroup {
          title: "Letters"
          chars: Model.GROUPS[0].chars
        }

        CharGroup {
          title: "Numbers"
          chars: Model.GROUPS[1].chars
        }

        CharGroup {
          title: "Punctuation"
          chars: Model.GROUPS[2].chars
        }
      }
    }
  }
}
