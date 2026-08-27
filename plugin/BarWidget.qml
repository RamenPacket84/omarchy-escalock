import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "StateModel.js" as StateModel

Panel {
  id: root
  moduleName: "andrewbacon.escalock"
  ipcTarget: "andrewbacon.escalock"
  manageIpc: false

  property string adminState: "inconsistent"
  property string statusMessage: "Checking authoritative system state…"
  property bool statusError: false
  property bool refreshPending: false
  property bool versionChecked: false
  property bool helperPresent: false
  property string installedSystemVersion: ""
  property bool onboardingOffered: false

  readonly property string helper: "/usr/local/libexec/omarchy-escalock-helper"
  readonly property string onboardingLauncher: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/andrewbacon.escalock/bin/omarchy-escalock-onboard"
  readonly property string expectedSystemVersion: "2.0.1"
  readonly property string setupState: StateModel.setupState(versionChecked,
    helperPresent, installedSystemVersion, expectedSystemVersion)
  readonly property bool setupMissing: setupState === "missing"
  readonly property bool updateRequired: setupState === "update"
  readonly property bool busy: helperProbe.running || versionProcess.running
    || statusProcess.running || transitionProcess.running || onboardingProcess.running
  readonly property string secureModeState: StateModel.secureState(adminState)
  readonly property string icon: secureModeState === "on" ? "\uf023"
    : (secureModeState === "off" ? "\uf09c" : "󰀦")
  readonly property string stateLabel: setupMissing ? "EscaLock setup"
    : (updateRequired ? "EscaLock update" : StateModel.stateLabel(adminState))
  readonly property string actionHint: setupMissing ? "finish setup"
    : (updateRequired ? "review the required update" : StateModel.actionHint(adminState))
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function refresh() {
    if (!versionChecked) {
      if (!helperProbe.running && !versionProcess.running) {
        helperProbe.command = ["/usr/bin/test", "-x", helper]
        helperProbe.running = true
      }
      return
    }
    if (setupMissing) {
      adminState = "inconsistent"
      statusMessage = "EscaLock system setup is required before Secure Mode can be used."
      statusError = true
      if (!onboardingOffered) {
        onboardingOffered = true
        onboardingTimer.restart()
      }
      return
    }
    if (updateRequired) {
      adminState = "inconsistent"
      statusMessage = "EscaLock system components must be updated to version "
        + expectedSystemVersion + ". Restore Administrator Mode before updating."
      statusError = true
      return
    }
    if (statusProcess.running) {
      refreshPending = true
      return
    }
    statusProcess.command = [helper, "status"]
    statusProcess.running = true
  }

  function recheck() {
    if (onboardingProcess.running) return
    versionChecked = false
    helperPresent = false
    installedSystemVersion = ""
    refresh()
  }

  function startSetup(automatic) {
    if (onboardingProcess.running || !setupMissing) return
    statusMessage = "Complete EscaLock setup in the opened terminal. Administrator Mode will remain ON."
    statusError = false
    close()
    onboardingProcess.command = automatic
      ? [onboardingLauncher, "--automatic"] : [onboardingLauncher]
    onboardingProcess.running = true
  }

  function requestToggle() {
    if (busy) return
    if (setupMissing || updateRequired) {
      open()
      return
    }
    if (adminState === "disabled") {
      runTransition("enable")
      return
    }
    statusMessage = adminState === "enabled"
      ? "Turning Secure Mode on blocks subsequent sudo and generic administrative elevation until you authenticate to turn it off."
      : "The sudo and Polkit state do not agree. Secure Mode cannot be determined, so no transition will be attempted."
    statusError = adminState !== "enabled"
    open()
  }

  function runTransition(operation) {
    if (busy || (operation !== "enable" && operation !== "disable")) return
    statusMessage = operation === "enable"
      ? "Waiting for authentication to turn Secure Mode off and restore administrator privileges…"
      : "Waiting for authentication to turn Secure Mode on…"
    statusError = false
    transitionProcess.operation = operation
    transitionProcess.command = ["/usr/bin/pkexec", helper, operation]
    transitionProcess.running = true
  }

  function finishStatus(exitCode, text) {
    var value = String(text || "").trim()
    if (exitCode === 0 && (value === "enabled" || value === "disabled" || value === "inconsistent")) {
      adminState = value
      if (!transitionProcess.running) {
        statusMessage = StateModel.statusMessage(value)
        statusError = value === "inconsistent"
      }
    } else {
      adminState = "inconsistent"
      statusMessage = "Could not verify authoritative system state."
      statusError = true
    }
  }

  Component.onCompleted: recheck()
  onOpenedChanged: if (opened) recheck()

  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: root.recheck()
  }

  Timer {
    id: onboardingTimer
    interval: 750
    repeat: false
    onTriggered: root.startSetup(true)
  }

  Process {
    id: helperProbe
    onExited: function(exitCode) {
      helperPresent = exitCode === 0
      if (helperPresent) {
        versionProcess.command = [helper, "version"]
        versionProcess.running = true
      } else {
        installedSystemVersion = ""
        versionChecked = true
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: versionProcess
    stdout: StdioCollector {
      id: versionOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var value = String(versionOutput.text || "").trim()
      installedSystemVersion = exitCode === 0 ? value : ""
      helperPresent = true
      versionChecked = true
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: onboardingProcess
    stderr: StdioCollector {
      id: onboardingError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var detail = String(onboardingError.text || "").trim()
        statusMessage = detail !== "" ? detail : "EscaLock setup could not be opened."
        statusError = true
        return
      }
      Qt.callLater(root.recheck)
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      id: statusOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.finishStatus(exitCode, statusOutput.text)
      var rerun = root.refreshPending
      root.refreshPending = false
      if (rerun) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: transitionProcess
    property string operation: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: transitionError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusMessage = operation === "enable"
          ? "Secure Mode turned off; verifying administrator access…"
          : "Secure Mode turned on; verifying restrictions…"
        root.statusError = false
      } else if (exitCode === 126) {
        root.statusMessage = "Authentication canceled. No change was made."
        root.statusError = false
      } else if (exitCode === 127) {
        root.statusMessage = "Authorization denied or unavailable. No change was assumed."
        root.statusError = true
      } else {
        var detail = String(transitionError.text || "").trim()
        root.statusMessage = detail !== "" ? detail : "Secure Mode transition failed."
        root.statusError = true
      }
      root.refreshPending = true
      Qt.callLater(root.refresh)
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.requestToggle() }
    function refresh() { root.recheck() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.icon : root.icon + "  " + root.stateLabel
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.stateLabel + (root.busy ? " · working…" : "")
      + "\nLeft-click: " + root.actionHint
      + " · Middle-click: refresh"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.recheck()
      else if (mouseButton === Qt.LeftButton) root.requestToggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: cancelButton
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Text {
          width: parent.width
          text: root.setupMissing ? "Finish EscaLock setup"
            : (root.updateRequired ? "EscaLock update required"
              : StateModel.panelTitle(root.adminState))
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: root.statusMessage
          textFormat: Text.PlainText
          color: root.statusError && root.bar ? root.bar.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            id: cancelButton
            width: (parent.width - parent.spacing) / 2
            text: root.adminState === "enabled" && !root.setupMissing
              && !root.updateRequired ? "Keep OFF" : "Close"
            enabled: !root.busy
            foreground: root.foreground
            onClicked: root.close()
          }

          Button {
            width: cancelButton.width
            text: root.setupMissing ? "Finish setup"
              : (root.adminState === "enabled" && !root.updateRequired ? "Turn ON" : "Refresh")
            enabled: !root.busy
            foreground: root.foreground
            onClicked: {
              if (root.setupMissing) root.startSetup(false)
              else if (root.adminState === "enabled" && !root.updateRequired)
                root.runTransition("disable")
              else root.recheck()
            }
          }
        }
      }
    }
  }
}
