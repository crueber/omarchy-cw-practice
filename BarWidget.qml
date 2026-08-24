import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar pill for CW Practice: a "CW" label that opens the practice panel.
// Lights up while a practice run is in progress.
BarWidget {
  id: root
  moduleName: "crueber.cwpractice"

  readonly property bool running: panelLoader.item ? panelLoader.item.wantRunning === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // State-changing IPC (start/stop/set) is disabled by default: any local
  // process able to reach the IPC target could otherwise start audio or
  // change persisted settings without a panel interaction. Opt in per the
  // README with "allowIpcControl": true in the widget's shell.json entry.
  readonly property bool ipcControlAllowed: panelLoader.item
    ? panelLoader.item.ipcControlAllowed === true : false

  IpcHandler {
    target: "crueber.cwpractice"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }

    function start(): string {
      if (!root.ipcControlAllowed) return "disabled: set allowIpcControl in shell.json"
      if (panelLoader.item) panelLoader.item.play()
      return "ok"
    }

    function stop(): string {
      if (!root.ipcControlAllowed) return "disabled: set allowIpcControl in shell.json"
      if (panelLoader.item) panelLoader.item.pause()
      return "ok"
    }

    // set <key> <value> — keys: wpm, delay, tone, volume, word-gaps, pool.
    // Applied live (next character) when a practice run is active.
    function set(key: string, value: string): string {
      if (!root.ipcControlAllowed) return "disabled: set allowIpcControl in shell.json"
      if (!panelLoader.item) return "panel not ready"
      return panelLoader.item.applySetting(key, value) ? "ok" : "unknown key: " + key
    }

    function history(): string {
      return panelLoader.item ? panelLoader.item.historyText : ""
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "CW"
    active: root.running
    tooltipText: "CW Practice — Morse code receiving"

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
