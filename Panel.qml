import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "r3mcos3.legion"
  ipcTarget: "r3mcos3.legion"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helper: pluginDir + "/bin/legionctl"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: Style.font.family

  property var roster: []
  property var cronJobs: []
  property var notifications: []
  property var tasks: []
  property var usage: null
  property bool soundEnabled: true
  property string listError: ""
  property string formError: ""

  readonly property int onlineCount: roster.filter(function(m) { return m.online }).length
  readonly property int offlineCount: roster.length - onlineCount

  function displaySafe(value) {
    return String(value == null ? "" : value)
      .replace(/[\x00-\x1f\x7f-\x9f\u061C\u200B-\u200F\u2028\u2029\u202A-\u202E\u2060\u2066-\u2069\uFEFF]/g, "\uFFFD")
  }

  function formatTimestamp(unixSeconds) {
    if (!unixSeconds) return ""
    var d = new Date(unixSeconds * 1000)
    return d.toLocaleString(Qt.locale(), "ddd d MMM HH:mm")
  }

  function formatLogTime(epochMs) {
    if (!epochMs) return ""
    var d = new Date(epochMs)
    return d.toLocaleTimeString(Qt.locale(), "HH:mm")
  }

  // --- generic JSON-producing process runner ----------------------------

  function runJson(args, onDone) {
    var p = jsonProcComponent.createObject(root, { command: [root.helper].concat(args) })
    p.runFinished.connect(function(exitCode) { onDone(exitCode, p.collectedText); p.destroy() })
    p.running = true
  }

  Component {
    id: jsonProcComponent
    Process {
      id: proc
      property string collectedText: ""
      signal runFinished(int exitCode)
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: proc.collectedText = text
      }
      onExited: function(exitCode) { runFinished(exitCode) }
    }
  }

  function refreshRoster() {
    runJson(["roster", "--json"], function(code, text) {
      if (code !== 0) { root.listError = "Kon roster niet laden."; return }
      try {
        root.roster = JSON.parse(text)
        root.listError = ""
      } catch (e) {
        root.listError = "Kon roster niet lezen."
      }
    })
  }

  function refreshCronJobs() {
    runJson(["cron-jobs", "--json"], function(code, text) {
      if (code !== 0) return
      try { root.cronJobs = JSON.parse(text) } catch (e) { root.cronJobs = [] }
    })
  }

  function refreshUsage() {
    runJson(["usage", "--json"], function(code, text) {
      if (code !== 0) return
      try {
        var v = JSON.parse(text)
        root.usage = (v && typeof v === "object") ? v : null
      } catch (e) { root.usage = null }
    })
  }

  function refreshNotifications() {
    runJson(["notifications", "--limit", "30"], function(code, text) {
      if (code !== 0) return
      try { root.notifications = JSON.parse(text) } catch (e) { root.notifications = [] }
    })
  }

  function refreshSettings() {
    runJson(["settings", "--json"], function(code, text) {
      if (code !== 0) return
      try {
        var v = JSON.parse(text)
        root.soundEnabled = (v && typeof v === "object") ? (v.soundEnabled !== false) : true
      } catch (e) { /* keep last known value */ }
    })
  }

  function toggleSound() { runAction(["settings", "sound", root.soundEnabled ? "off" : "on"]) }

  function refreshTasks() {
    runJson(["tasks", "list", "--json"], function(code, text) {
      if (code !== 0) return
      try { root.tasks = JSON.parse(text) } catch (e) { root.tasks = [] }
    })
  }

  function refreshAll() {
    refreshRoster()
    refreshCronJobs()
    refreshUsage()
    refreshNotifications()
    refreshTasks()
    refreshSettings()
  }

  // --- actions (mutating) --------------------------------------------------

  property bool actionBusy: false

  function runAction(args, onDone) {
    if (root.actionBusy) return
    root.actionBusy = true
    root.formError = ""
    var p = actionProcComponent.createObject(root, { command: [root.helper].concat(args) })
    p.runFinished.connect(function(exitCode, stderrText) {
      root.actionBusy = false
      if (exitCode !== 0) {
        root.formError = stderrText || "Actie mislukt."
      } else if (onDone) {
        onDone()
      }
      refreshAll()
      p.destroy()
    })
    p.running = true
  }

  Component {
    id: actionProcComponent
    Process {
      id: proc
      property string stdoutText: ""
      property string stderrText: ""
      signal runFinished(int exitCode, string stderrOutput)
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: proc.stdoutText = text }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: proc.stderrText = text.trim() }
      onExited: function(exitCode) { runFinished(exitCode, proc.stderrText) }
    }
  }

  // Routed through legionctl's "terminal open" instead of spawning Alacritty
  // straight from here, so a second click on the same member's row finds and
  // refocuses the window it already opened (moved to the current workspace)
  // rather than opening a duplicate one attached to the same session. See
  // cmd_terminal_open in bin/legionctl for the TUI.float / --title
  // "legion:<name>" matching convention this depends on.
  function openTerminalFor(id, name) {
    runAction(["terminal", "open", name, id])
    root.pendingTrackName = name
    terminalTrackTimer.restart()
  }

  // --- click-outside-to-close for the floating terminal -----------------
  //
  // A newly-launched window isn't mapped yet the instant "terminal open"
  // returns (confirmed live: ~1-2s), so this waits a beat, then asks
  // legionctl for that member's window address and starts watching
  // Hyprland's active toplevel. The moment focus moves to anything else —
  // clicking elsewhere, another window, another workspace — that terminal
  // is closed, the same as a quake-style dropdown terminal, instead of
  // needing a keybinding every time.
  property string pendingTrackName: ""
  property string trackedTerminalName: ""
  property string trackedTerminalAddress: ""

  Timer {
    id: terminalTrackTimer
    interval: 1800
    onTriggered: {
      var name = root.pendingTrackName
      runJson(["terminal", "find", name], function(code, text) {
        if (code !== 0) return
        try {
          var v = JSON.parse(text)
          if (v && v.address) {
            root.trackedTerminalName = name
            root.trackedTerminalAddress = v.address
          }
        } catch (e) { /* window never mapped (launch failed) — nothing to track */ }
      })
    }
  }

  // Quickshell's Hyprland.activeToplevel.address omits the "0x" prefix that
  // `hyprctl clients -j` (and therefore legionctl's own address lookups)
  // includes — confirmed live, the two would otherwise never match even for
  // the same window. Normalize both sides before comparing.
  function normalizeAddress(addr) { return String(addr || "").replace(/^0x/, "") }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      if (!root.trackedTerminalAddress) return
      var active = Hyprland.activeToplevel
      var activeAddress = root.normalizeAddress(active ? active.address : "")
      if (activeAddress === root.normalizeAddress(root.trackedTerminalAddress)) return
      var closingName = root.trackedTerminalName
      root.trackedTerminalName = ""
      root.trackedTerminalAddress = ""
      runAction(["terminal", "close", closingName])
    }
  }

  function startAll() { runAction(["start-all"]) }

  function startMember(name) { runAction(["session", "start", name]) }
  function stopMember(name) { runAction(["session", "stop", name]) }
  function restartMember(name) { runAction(["session", "restart", name]) }

  function addMember() {
    var name = memberNameField.text.trim()
    var cwd = memberCwdField.text.trim()
    if (!name || !cwd) { root.formError = "Naam en werkmap zijn verplicht."; return }
    runAction(["members", "add", name, cwd], function() {
      memberNameField.text = ""
      memberCwdField.text = ""
    })
  }

  function addTask() {
    var member = taskMemberField.value
    var title = taskTitleField.text.trim()
    var message = taskMessageField.text.trim()
    if (!member || !title || !message) { root.formError = "Lid, titel en tekst zijn verplicht."; return }
    if (root.actionBusy) return
    root.actionBusy = true
    root.formError = ""
    var p = actionProcComponent.createObject(root, {
      command: [root.helper, "tasks", "add", member, title],
      environment: { "LEGION_MESSAGE": message }
    })
    p.runFinished.connect(function(exitCode, stderrText) {
      root.actionBusy = false
      if (exitCode !== 0) {
        root.formError = stderrText || "Aanmaken opdracht mislukt."
      } else {
        // Leave taskMemberField's selection as-is — convenient when sending
        // several tasks to the same member in a row, and there is no
        // natural "empty" value for a dropdown the way a blank TextField has.
        taskTitleField.text = ""
        taskMessageField.text = ""
      }
      refreshAll()
      p.destroy()
    })
    p.running = true
  }

  function sendTask(id) { runAction(["tasks", "send", id]) }
  function doneTask(id) { runAction(["tasks", "done", id]) }

  // --- notifications (always on, independent of the panel being open) ------
  //
  // "Done with your task" isn't observable as a one-off event — it's a
  // change in shared state (tasks.json's status field, flipped by the
  // webapp's own reply detection or a manual "klaar"), so this polls for
  // it rather than listening for a push. Runs constantly from
  // Component.onCompleted, not just while the panel is open, since the
  // whole point is finding out without having to check.
  //
  // unseenMembers (not a count) drives two things: the bar icon blinks
  // whenever it's non-empty, and each named member's own roster row blinks
  // too, so opening the panel points straight at who actually needs
  // attention instead of a bare number.
  property var unseenMembers: []
  readonly property bool hasUnseen: unseenMembers.length > 0

  function checkNotifications() {
    runJson(["notifications", "check"], function(code, text) {
      if (code !== 0) return
      try {
        var result = JSON.parse(text)
        root.unseenMembers = result.unseenMembers || []
      } catch (e) { /* transient parse hiccup — next poll corrects it */ }
    })
  }

  function markNotificationsSeen() {
    root.unseenMembers = []
    runJson(["notifications", "mark-seen"], function() {})
  }

  Timer {
    id: notifyTimer
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkNotifications()
  }

  onOpenedChanged: if (opened) {
    refreshAll()
    markNotificationsSeen()
    refreshTimer.start()
  } else {
    refreshTimer.stop()
  }

  Timer {
    id: refreshTimer
    interval: 5000
    repeat: true
    onTriggered: refreshAll()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0c0"
    tooltipText: [
      root.offlineCount > 0 ? (root.offlineCount + " offline") : "",
      root.hasUnseen ? ("reactie van " + root.unseenMembers.join(", ")) : ""
    ].filter(function(s) { return s !== "" }).join(" \u00b7 ") || "Legion"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }

  Rectangle {
    anchors.fill: button
    anchors.margins: -Style.space(2)
    radius: Math.max(4, Style.cornerRadius)
    color: Util.alpha(Color.urgent, 0.30)
    border.width: 1
    border.color: Color.urgent
    visible: root.offlineCount > 0
  }

  // Blinks the bar icon itself instead of a numbered badge -- see
  // checkNotifications / RosterRow.isUnseen for the matching per-member
  // blink in the roster list below. Both stop the moment the panel opens.
  SequentialAnimation {
    running: root.hasUnseen
    loops: Animation.Infinite
    onRunningChanged: if (!running) button.opacity = 1.0
    NumberAnimation { target: button; property: "opacity"; from: 1.0; to: 0.3; duration: 550; easing.type: Easing.InOutQuad }
    NumberAnimation { target: button; property: "opacity"; from: 0.3; to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: !keyCatcher.activeFocus
      onCloseRequested: root.close()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width - Style.space(12)
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: "Legion"
            meta: root.onlineCount + " online" + (root.offlineCount > 0 ? " · " + root.offlineCount + " offline" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // --- usage -----------------------------------------------------
          Row {
            visible: root.usage !== null
            width: parent.width
            spacing: Style.space(10)

            PanelToolTip {
              visible: usageHover.hovered
              fontFamily: root.fontFamily
              text: root.usage
                ? "5h reset: " + root.formatTimestamp(root.usage.resets5h)
                  + "\n7d reset: " + root.formatTimestamp(root.usage.resets7d)
                : ""
            }
            HoverHandler { id: usageHover }

            Text {
              textFormat: Text.PlainText
              text: root.usage ? "5h " + root.usage.fiveHour + "%  ·  7d " + root.usage.sevenDay + "%" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // --- roster ------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "LEDEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Button {
              text: "Start alles"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              enabled: !root.actionBusy
              onClicked: root.startAll()
            }
          }

          Repeater {
            model: root.roster
            RosterRow { width: contentColumn.width; entry: modelData }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)
            enabled: !root.actionBusy

            TextField {
              id: memberNameField
              width: Style.space(96)
              placeholderText: "naam"
              foreground: root.foreground
              font.family: root.fontFamily
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
            }
            TextField {
              id: memberCwdField
              Layout.fillWidth: true
              width: parent.width - memberNameField.width - addMemberButton.width - Style.space(8)
              placeholderText: "/absoluut/pad"
              foreground: root.foreground
              font.family: root.fontFamily
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
            }
            Button {
              id: addMemberButton
              text: "Toevoegen"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(6)
              onClicked: root.addMember()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // --- tasks ---------------------------------------------------------
          PanelSectionHeader {
            width: parent.width
            text: "OPDRACHTEN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.tasks.length === 0
            width: parent.width
            text: "Geen opdrachten."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.tasks.filter(function(t) { return t.status !== "done" })
            TaskRow { width: contentColumn.width; entry: modelData }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            enabled: !root.actionBusy

            Dropdown {
              id: taskMemberField
              width: parent.width
              showLabel: false
              // Always the live roster (fixed + dynamic + whatever's been
              // added since), not a hardcoded list — a future member shows
              // up here the moment it appears in roster.json/agents --json.
              options: root.roster.map(function(m) { return m.name })
              // Defaults to the first roster entry so a quick title+message
              // doesn't require touching the dropdown at all; picking one by
              // hand overrides this binding (standard QML: an imperative
              // assignment breaks an existing property binding) and sticks
              // across later roster refreshes.
              value: root.roster.length ? root.roster[0].name : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            TextField {
              id: taskTitleField
              width: parent.width
              placeholderText: "titel"
              foreground: root.foreground
              font.family: root.fontFamily
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
            }
            TextField {
              id: taskMessageField
              width: parent.width
              placeholderText: "opdrachttekst"
              foreground: root.foreground
              font.family: root.fontFamily
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
            }
            Button {
              text: "Nieuwe opdracht"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(6)
              onClicked: root.addTask()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.formError !== ""
            width: parent.width
            text: root.displaySafe(root.formError)
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // --- cron jobs -----------------------------------------------------
          PanelSectionHeader {
            width: parent.width
            text: "CRONJOBS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.cronJobs.length === 0
            width: parent.width
            text: "Geen cronjobs geconfigureerd."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.cronJobs
            Column {
              width: contentColumn.width
              spacing: Style.space(1)
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.displaySafe(modelData.description || modelData.id)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.displaySafe(modelData.cron) + (modelData.recurring ? "  ·  herhalend" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // --- notifications -------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "MELDINGEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.soundEnabled
              busy: root.actionBusy
              foreground: root.foreground
              onToggled: root.toggleSound()
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "geluid"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.notifications.length === 0
            width: parent.width
            text: "Geen recente meldingen."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.notifications.slice().reverse()
            Row {
              width: contentColumn.width
              spacing: Style.space(6)
              Text {
                textFormat: Text.PlainText
                text: root.formatLogTime(modelData.ts)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                textFormat: Text.PlainText
                width: contentColumn.width - Style.space(50)
                text: root.displaySafe(modelData.text)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }

  component RosterRow: CursorSurface {
    id: rosterRow
    property var entry: null
    readonly property bool isUnseen: rosterRow.entry
      ? root.unseenMembers.indexOf(rosterRow.entry.name) !== -1 : false

    foreground: root.foreground
    hasCursor: rowHover.hovered
    implicitHeight: rowLayout.implicitHeight + Style.space(4)

    HoverHandler { id: rowHover }

    // Points at exactly who replied/asked something, instead of a bare
    // count elsewhere — stops the moment the panel is opened (see
    // markNotificationsSeen), same trigger as the bar icon's own blink.
    SequentialAnimation {
      running: rosterRow.isUnseen
      loops: Animation.Infinite
      onRunningChanged: if (!running) rosterRow.opacity = 1.0
      NumberAnimation { target: rosterRow; property: "opacity"; from: 1.0; to: 0.35; duration: 550; easing.type: Easing.InOutQuad }
      NumberAnimation { target: rosterRow; property: "opacity"; from: 0.35; to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      spacing: Style.space(6)

      Rectangle {
        width: Style.space(7)
        height: Style.space(7)
        radius: width / 2
        color: rosterRow.entry && rosterRow.entry.online ? Color.accent : Color.urgent
      }

      Text {
        textFormat: Text.PlainText
        Layout.preferredWidth: Style.space(78)
        text: rosterRow.entry ? root.displaySafe(rosterRow.entry.name) : ""
        color: rosterRow.entry && rosterRow.entry.isBoss ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: rosterRow.entry ? rosterRow.entry.isBoss : false
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: rosterRow.entry ? root.displaySafe(rosterRow.entry.status || (rosterRow.entry.online ? "online" : "offline")) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        visible: rowHover.hovered
        spacing: Style.space(4)

        Button {
          visible: rosterRow.entry && rosterRow.entry.online
          text: "terminal"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.openTerminalFor(rosterRow.entry.id, rosterRow.entry.name)
        }
        Button {
          visible: rosterRow.entry && !rosterRow.entry.online
          text: "start"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.startMember(rosterRow.entry.name)
        }
        Button {
          visible: rosterRow.entry && rosterRow.entry.online && !rosterRow.entry.isBoss
          text: "stop"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.stopMember(rosterRow.entry.name)
        }
      }
    }
  }

  component TaskRow: Column {
    id: taskRow
    property var entry: null
    spacing: Style.space(2)

    RowLayout {
      width: parent.width
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        Layout.preferredWidth: Style.space(70)
        text: taskRow.entry ? root.displaySafe(taskRow.entry.member) : ""
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: taskRow.entry ? root.displaySafe(taskRow.entry.title) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        text: taskRow.entry ? root.displaySafe(taskRow.entry.status) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Row {
      spacing: Style.space(4)
      Button {
        visible: taskRow.entry && taskRow.entry.status === "backlog"
        text: "versturen"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(2)
        onClicked: root.sendTask(taskRow.entry.id)
      }
      Button {
        text: "klaar"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(6)
        verticalPadding: Style.space(2)
        onClicked: root.doneTask(taskRow.entry.id)
      }
    }
  }
}
