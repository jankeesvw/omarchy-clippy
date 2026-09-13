import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Tips.js" as TipData
import "ClippyRig.js" as Rig

// Clippy: a paperclip in the bottom-right corner of the screen. His eyes follow
// the mouse, he bends his wire into the shapes the original Office Assistant
// knew (a bicycle, an atom, a pile of rope, a check mark), falls asleep when
// you walk away, and hands out tips from the Omarchy manual.
//
// shell.json settings (top-level plugins[] entry):
//   { "id": "jankeesvw.clippy",
//     "intervalMinutes": 20,   // unprompted tip every N minutes, 0 = only on click
//     "greeting": true,        // say hello when the shell starts
//     "monitor": "DP-3",       // output name; default is the monitor focused at start
//     "marginX": 24, "marginY": 24 }
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "jankeesvw.clippy"

  // ------------------------------------------------------------- settings

  function setting(key, fallback) {
    var cfg = shell ? shell.shellConfig : null
    var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (entry && String(entry.id || "") === root.pluginId && entry[key] !== undefined)
        return entry[key]
    }
    return fallback
  }

  function settingInt(key, fallback, min, max) {
    var n = Number(setting(key, fallback))
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.round(n)))
  }

  readonly property int intervalMinutes: settingInt("intervalMinutes", 20, 0, 1440)
  readonly property int marginX: settingInt("marginX", 24, 0, 4000)
  readonly property int marginY: settingInt("marginY", 24, 0, 4000)
  readonly property bool greeting: setting("greeting", true) !== false
  readonly property bool dodge: setting("dodge", true) !== false
  readonly property string monitorSetting: {
    var value = String(setting("monitor", ""))
    return /^[A-Za-z0-9._-]{1,64}$/.test(value) ? value : ""
  }

  // Clippy stays on the monitor that had focus when he arrived, rather than
  // jumping between outputs every time focus moves.
  property string startMonitor: ""
  function latchStartMonitor() {
    if (root.startMonitor === "" && Hyprland.focusedMonitor)
      root.startMonitor = String(Hyprland.focusedMonitor.name || "")
  }
  Connections {
    target: Hyprland
    function onFocusedMonitorChanged() { root.latchStartMonitor() }
    // Focusing a window means you are done with Clippy.
    function onRawEvent(event) {
      if (root.keysWanted && event && String(event.name).indexOf("activewindow") === 0) root.deselect()
    }
  }

  readonly property var targetScreen: {
    var screens = Quickshell.screens
    var wanted = root.monitorSetting !== "" ? root.monitorSetting : root.startMonitor
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === wanted) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  function px(n) { return Style.space(n) }
  readonly property real artScale: Style.spaceReal(1) * 0.95

  // Fixed palette: a steel paperclip on a yellow legal pad and a sticky-note
  // bubble read the same on every theme and every wallpaper.
  readonly property color ink: "#1c1c18"
  readonly property color inkSoft: "#6a6754"
  readonly property color paper: "#fffbd6"
  readonly property color paperHover: "#fff4ad"
  readonly property color paperPressed: "#f1e48c"
  readonly property color pad: "#f4efb4"
  readonly property color padLine: "#c9c27f"
  readonly property color wireDark: "#2a2e35"
  readonly property color wireMetal: "#b7bfca"
  readonly property color wireShine: "#f4f7fb"

  // ---------------------------------------------------------------- state

  property bool present: true
  property bool bubbleOpen: false
  property string bubbleKind: "tip"      // tip | hello | goodbye
  property string bubbleTitle: ""
  property var tip: null
  property bool hovered: false
  property bool sleeping: false

  // Dragging, selection and getting out of the way.
  property bool dragging: false
  property int posRight: 0
  property int posBottom: 0
  property bool keysWanted: false
  readonly property bool selected: root.keysWanted && root.present
  property bool ghost: false
  property bool claimed: false
  property real dwellSince: 0

  property real cursorX: 0
  property real cursorY: 0
  property bool cursorKnown: false
  property real lastMoveAt: Date.now()

  property string lookMode: "cursor"     // cursor | bubble | wander
  property real wanderX: 0
  property real openness: 1
  property real browLift: 0

  // The wire rig: Clippy is drawn as pose `shapeA` blended into `shapeB`.
  property string shapeA: "clip"
  property string shapeB: "clip"
  property real morph: 0
  property real phase: 0
  property real ride: 0
  property real eyeBoost: 1
  property real glasses: 0
  property real headphones: 0
  property real ripple: 0

  readonly property var pose: Rig.pose(root.shapeA, root.shapeB, root.morph, root.phase, root.ride)
  readonly property var wirePath: root.pose.pts.map(function(p) { return Qt.point(p.x, p.y) })

  function beginMorph(name) {
    root.shapeA = root.morph >= 0.5 ? root.shapeB : root.shapeA
    root.shapeB = String(name)
    root.morph = 0
  }

  function resetRig() {
    root.shapeA = "clip"
    root.shapeB = "clip"
    root.morph = 0
    root.phase = 0
    root.ride = 0
    root.eyeBoost = 1
    root.glasses = 0
    root.headphones = 0
    root.ripple = 0
  }

  readonly property var titles: [
    "Did you know?",
    "It looks like you're using Omarchy!",
    "Here's a tip!",
    "Psst!",
    "Quick one!"
  ]

  property string agentText: ""

  readonly property string bubbleBody: {
    if (root.bubbleKind === "agent")
      return root.tipMarkup(root.agentText)
    if (root.bubbleKind === "hello")
      return "It looks like you're using Omarchy! Click me any time and I'll show you something from the manual."
    if (root.bubbleKind === "goodbye")
      return "I can ride off for the rest of this session. Bring me back with <b>omarchy-shell jankeesvw.clippy show</b>."
    return root.tip ? root.tipMarkup(root.tip.text) : ""
  }

  // ----------------------------------------------------------------- tips

  property var deck: []

  function nextTip() {
    var all = TipData.tips
    if (!all || all.length === 0) return null
    var order = root.deck
    if (order.length === 0) {
      order = []
      for (var i = 0; i < all.length; i++) order.push(i)
      for (var j = order.length - 1; j > 0; j--) {
        var k = Math.floor(Math.random() * (j + 1))
        var swap = order[j]; order[j] = order[k]; order[k] = swap
      }
    }
    var index = order[order.length - 1]
    root.deck = order.slice(0, -1)
    return all[index]
  }

  function escapeHtml(value) {
    return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // Tips are bundled with the plugin, but they still go through escaping: the
  // only markup that reaches StyledText is the <b> this function adds.
  function tipMarkup(text) {
    return root.escapeHtml(String(text || "").slice(0, 400))
      .replace(/`([^`]{1,80})`/g, "<b>$1</b>")
  }

  // What he does when you ask for a tip. Never the same one twice in a row.
  readonly property var tipReactions: ["point", "scratch", "bang", "glasses", "brows", "hop", "wiggle", "flip", "atom"]
  property string lastReaction: ""

  function tipReaction() {
    var options = root.tipReactions.filter(function(name) { return name !== root.lastReaction })
    root.lastReaction = root.pick(options)
    return root.lastReaction
  }

  function showTip(animation) {
    var next = root.nextTip()
    if (!next) return
    root.tip = next
    root.bubbleKind = "tip"
    root.bubbleTitle = root.titles[Math.floor(Math.random() * root.titles.length)]
    root.openBubble(animation)
  }

  function sayHello() {
    root.tip = null
    root.bubbleKind = "hello"
    root.bubbleTitle = "Hi! I'm Clippy."
    root.openBubble("bang")
  }

  // Anything can ask Clippy to say something: an agent that finished, a build
  // that broke. Control characters go, the length is capped, and the text is
  // escaped like a tip, so `code` is the only markup that survives.
  function plainLine(value, max) {
    return String(value || "").replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").trim().slice(0, max)
  }

  property var agentLinks: []

  // Links from outside: https to anywhere, http only to this machine, and
  // nothing with credentials, whitespace, quotes or control characters in it.
  // omarchy-launch-browser rewrites "--private" inside its arguments, so that
  // is refused too.
  function safeUrl(value) {
    var url = String(value || "")
    if (url.length === 0 || url.length > 2048) return ""
    if (/[\s\u0000-\u001f\u007f-\u009f<>"'`\\]/.test(url) || url.indexOf("--private") >= 0) return ""
    var match = /^(https?):\/\/([^\/?#]*)/i.exec(url)
    if (!match || match[2].indexOf("@") >= 0) return ""
    var host = match[2].replace(/:\d{1,5}$/, "").toLowerCase()
    if (host === "") return ""
    if (match[1].toLowerCase() === "http" && !/^(localhost|127\.0\.0\.1|\[::1\])$/.test(host)) return ""
    return url
  }

  function linkButton(label, url) {
    var cleanLabel = root.plainLine(label, 24)
    var cleanUrl = root.safeUrl(url)
    return cleanLabel !== "" && cleanUrl !== "" ? { label: cleanLabel, url: cleanUrl } : null
  }

  function openLink(link) {
    var url = link ? root.safeUrl(link.url) : ""
    if (url === "") return
    Quickshell.execDetached(["omarchy-launch-browser", url])
    root.closeBubble()
    root.play("check")
  }

  function say(title, text, links) {
    var body = root.plainLine(text, 300)
    if (body === "") return false
    root.tip = null
    root.agentText = body
    root.agentLinks = (links || []).filter(function(link) { return link !== null }).slice(0, 2)
    root.bubbleKind = "agent"
    root.bubbleTitle = root.plainLine(title, 80) || "Your agent says"
    root.openBubble("attention")
    return true
  }

  function askGoodbye() {
    root.tip = null
    root.bubbleKind = "goodbye"
    root.bubbleTitle = "Want me to go away?"
    root.openBubble("pile")
  }

  function openBubble(animation) {
    if (!root.present) return
    if (root.sleeping) root.wake()
    root.lastMoveAt = Date.now()
    root.interacted()
    root.bubbleOpen = true
    autoHide.interval = root.bubbleKind === "tip" || root.bubbleKind === "agent" ? 30000 : 14000
    autoHide.restart()
    root.play(animation)
    if (animation !== "point") root.glanceAtBubble()
  }

  function closeBubble() {
    root.bubbleOpen = false
    autoHide.stop()
    root.interacted()
  }

  function openManual() {
    var url = root.tip ? String(root.tip.url || "") : ""
    if (!/^https:\/\/omarchy\.org\/manual\/[a-z0-9-]{1,64}\/$/.test(url)) return
    Quickshell.execDetached(["omarchy-launch-webapp", url])
    root.closeBubble()
    root.play("check")
  }

  function primaryAction() {
    if (root.bubbleKind === "agent") {
      if (root.agentLinks.length > 0) root.openLink(root.agentLinks[0])
      else { root.closeBubble(); root.play("check") }
    }
    else if (root.bubbleKind === "tip") root.openManual()
    else if (root.bubbleKind === "goodbye") root.goAway()
    else root.showTip(root.tipReaction())
  }

  function secondaryAction() {
    if (root.bubbleKind === "agent" && root.agentLinks.length > 1) root.openLink(root.agentLinks[1])
    else if (root.bubbleKind === "tip") root.showTip(root.tipReaction())
    else if (root.bubbleKind === "goodbye") { root.closeBubble(); root.play("hop") }
    else root.closeBubble()
  }

  Timer {
    id: autoHide
    interval: 30000
    onTriggered: if (!bubbleHover.hovered) root.closeBubble()
  }

  Timer {
    interval: Math.max(1, root.intervalMinutes) * 60000
    repeat: true
    running: root.present && root.intervalMinutes > 0
    onTriggered: if (!root.sleeping && !root.bubbleOpen) root.showTip("attention")
  }

  // ---------------------------------------------------------------- mouse

  // The helper streams "x y" in global layout coordinates, and only when the
  // pointer actually moved.
  readonly property string helperPath: {
    var raw = String(Qt.resolvedUrl("bin/clippy-cursor"))
    return raw.indexOf("file://") === 0 ? decodeURIComponent(raw.slice(7)) : ""
  }
  property int helperRestarts: 0

  function cursorLine(line) {
    var match = /^(-?\d{1,6}) (-?\d{1,6})$/.exec(String(line).slice(0, 32))
    if (!match) return
    root.cursorX = Number(match[1])
    root.cursorY = Number(match[2])
    root.cursorKnown = true
    root.lastMoveAt = Date.now()
    root.helperRestarts = 0
    if (root.sleeping) root.wake()
    root.releaseKeysIfAway()
  }

  Process {
    id: cursorProc
    command: ["/usr/bin/python3", "-I", "-S", root.helperPath]
    clearEnvironment: true
    environment: ({
      "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || ""
    })
    stdout: SplitParser {
      onRead: function(line) { root.cursorLine(line) }
    }
    onExited: function(code, status) {
      if (root.present && root.helperRestarts < 8) helperRestart.start()
    }
  }

  Timer {
    id: helperRestart
    interval: 2000 * (root.helperRestarts + 1)
    onTriggered: {
      root.helperRestarts++
      if (root.present && root.helperPath !== "") cursorProc.running = true
    }
  }

  onPresentChanged: {
    helperRestart.stop()
    cursorProc.running = root.present && root.helperPath !== ""
  }

  Component.onDestruction: cursorProc.running = false

  // How far a pupil should sit from the centre of its eye, per axis, -1..1.
  // Saturates with distance so the eyes keep moving when the pointer is far
  // away without pinning to the edge the moment it leaves Clippy.
  function gaze(eye, axis) {
    var cx = root.cursorX, cy = root.cursorY, mode = root.lookMode, wander = root.wanderX
    var anchor = root.pose
    if (mode === "bubble") return axis === 0 ? -0.5 : -0.85
    if (mode === "wander") return axis === 0 ? wander : 0.1
    if (root.sleeping || !root.cursorKnown || !eye || !win.screen || !anchor) return 0
    var p = eye.mapToItem(null, eye.width / 2, eye.height / 2)
    var dx = cx - (win.screen.x + p.x)
    var dy = cy - (win.screen.y + p.y)
    var d = Math.sqrt(dx * dx + dy * dy)
    if (d < 1) return 0
    var reach = d / (d + root.px(36))
    return (axis === 0 ? dx : dy) / d * reach
  }

  function glanceAtBubble() {
    root.lookMode = "bubble"
    glanceTimer.restart()
  }

  Timer {
    id: glanceTimer
    interval: 1300
    onTriggered: if (root.lookMode === "bubble") root.lookMode = "cursor"
  }

  // ------------------------------------------------- moving him around

  function moveTo(right, bottom) {
    root.posRight = Math.round(Math.max(0, Math.min(win.width - stage.width, right)))
    root.posBottom = Math.round(Math.max(0, Math.min(win.height - stage.height, bottom)))
  }

  function nudge(dx, dy) {
    root.moveTo(root.posRight - dx, root.posBottom - dy)
    saveTimer.restart()
  }

  // The position lives on our own plugins[] entry in shell.json, merged with
  // whatever other settings the entry already carries.
  function savePosition() {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") return
    var settings = {}
    var cfg = root.shell.shellConfig
    var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (entry && String(entry.id || "") === root.pluginId)
        for (var key in entry) if (key !== "id") settings[key] = entry[key]
    }
    settings.marginX = root.posRight
    settings.marginY = root.posBottom
    root.shell.updateEntryInline(root.pluginId, settings)
  }

  Timer {
    id: saveTimer
    interval: 700
    onTriggered: root.savePosition()
  }

  function beginDrag() {
    if (root.dragging || greetAnim.running || byeAnim.running) return
    dropAnim.stop()
    if (root.sleeping) { root.sleeping = false; sleepAnim.stop() }
    root.stopActions()
    root.openness = 1
    root.eyeBoost = 1.25
    root.ghost = false
    root.dragging = true
    grab.moved = true
  }

  function endDrag() {
    root.dragging = false
    root.interacted()
    root.savePosition()
    dropAnim.start()
  }

  SequentialAnimation {
    id: dropAnim
    ParallelAnimation {
      NumberAnimation { target: shake; property: "angle"; to: 0; duration: 700; easing.type: Easing.OutElastic }
      NumberAnimation { target: root; property: "eyeBoost"; to: 1; duration: 300; easing.type: Easing.OutQuad }
    }
  }

  // Clippy only has the keyboard while you are dealing with him. A layer that
  // asks for the keyboard on demand is handed it the moment it appears, so he
  // asks for none at all until you click him, and gives it back as soon as
  // you press Escape, wait a few seconds, move away, or focus a window.
  function claimKeys() {
    root.keysWanted = true
    keyRelease.restart()
    Qt.callLater(function() { keyTarget.forceActiveFocus() })
  }

  function deselect() {
    root.keysWanted = false
    keyRelease.stop()
  }

  Timer {
    id: keyRelease
    interval: 8000
    onTriggered: root.deselect()
  }

  function releaseKeysIfAway() {
    if (!root.keysWanted || !win.screen) return
    var sx = win.screen.x, sy = win.screen.y
    var margin = root.px(160)
    var left = sx + Math.min(stage.x, bubble.visible ? bubble.x : stage.x) - margin
    var right = sx + Math.max(stage.x + stage.width, bubble.visible ? bubble.x + bubble.width : 0) + margin
    var top = sy + Math.min(stage.y, bubble.visible ? bubble.y : stage.y) - margin
    var bottom = sy + Math.max(stage.y + stage.height, bubble.visible ? bubble.y + bubble.height : 0) + margin
    if (root.cursorX < left || root.cursorX > right || root.cursorY < top || root.cursorY > bottom)
      root.deselect()
  }

  // Getting out of the way: when the pointer comes near without aiming for
  // him, he turns see-through and lets clicks pass. Rest the pointer on him
  // for a moment and he is solid again.
  function updateGhost() {
    if (!root.dodge || !root.present || root.dragging || root.bubbleOpen || root.selected
        || root.sleeping || !root.cursorKnown || !win.screen) {
      root.ghost = false
      root.claimed = false
      root.dwellSince = 0
      return
    }
    var left = win.screen.x + stage.x
    var top = win.screen.y + stage.y + stage.height - body.height
    var right = left + stage.width
    var bottom = top + body.height
    var margin = root.px(36)
    var cx = root.cursorX, cy = root.cursorY
    var near = cx >= left - margin && cx <= right + margin && cy >= top - margin && cy <= bottom + margin
    if (!near) {
      root.ghost = false
      root.claimed = false
      root.dwellSince = 0
      return
    }
    if (root.claimed) {
      root.ghost = false
      return
    }
    var inside = cx >= left && cx <= right && cy >= top && cy <= bottom
    if (inside) {
      if (root.dwellSince === 0) {
        root.dwellSince = Date.now()
      } else if (Date.now() - root.dwellSince > 600) {
        root.claimed = true
        root.ghost = false
        root.play("brows")
        return
      }
    } else {
      root.dwellSince = 0
    }
    root.ghost = true
  }

  Timer {
    interval: 120
    repeat: true
    running: root.dodge && root.present && root.cursorKnown
    onTriggered: root.updateGhost()
  }

  // ----------------------------------------------------------- animations

  readonly property var animations: ({
    hop: hopAnim, attention: attentionAnim, wiggle: wiggleAnim, flip: flipAnim,
    look: lookAnim, brows: browsAnim, atom: atomAnim, pile: pileAnim, check: checkAnim,
    bang: bangAnim, point: pointAnim, scratch: scratchAnim, tap: tapAnim,
    glasses: glassesAnim, music: musicAnim
  })

  function anyRunning() {
    for (var name in root.animations)
      if (root.animations[name].running) return true
    return false
  }

  function stopActions() {
    for (var name in root.animations) root.animations[name].stop()
    wakeAnim.stop()
    action.xScale = 1
    action.yScale = 1
    shake.angle = 0
    if (!greetAnim.running && !byeAnim.running) {
      lift.y = 0
      root.resetRig()
    }
    root.browLift = 0
    if (root.lookMode === "wander") root.lookMode = "cursor"
  }

  function play(name) {
    if (!root.present || greetAnim.running || byeAnim.running) return
    var animation = root.animations[String(name)]
    if (!animation) return
    if (root.sleeping) root.wake()
    root.stopActions()
    animation.start()
  }

  function flourish() {
    root.play(root.pick(root.smallIdles.concat(root.bigIdles)))
  }

  function fallAsleep() {
    if (root.sleeping) return
    root.stopActions()
    root.closeBubble()
    root.sleeping = true
    sleepAnim.start()
  }

  function wake() {
    if (!root.sleeping) return
    root.sleeping = false
    sleepAnim.stop()
    wakeAnim.start()
  }

  function goAway() {
    root.closeBubble()
    if (root.sleeping) { root.sleeping = false; sleepAnim.stop(); root.openness = 1 }
    root.stopActions()
    if (root.present && !byeAnim.running) {
      greetAnim.stop()
      byeAnim.start()
    }
  }

  function summon() {
    if (root.present && !byeAnim.running) return
    byeAnim.stop()
    root.present = true
    root.interacted()
    greetAnim.start()
  }

  Component.onCompleted: {
    root.posRight = root.marginX
    root.posBottom = root.marginY
    root.latchStartMonitor()
    cursorProc.running = root.helperPath !== ""
    greetAnim.start()
    if (root.greeting) helloTimer.start()
  }

  Timer {
    id: helloTimer
    interval: 3600
    onTriggered: root.sayHello()
  }

  // Blinking, with the occasional double blink.
  Timer {
    interval: 3000
    running: root.present
    repeat: true
    onTriggered: {
      interval = 2200 + Math.random() * 4200
      if (root.sleeping || blinkAnim.running || doubleBlinkAnim.running) return
      if (Math.random() < 0.18) doubleBlinkAnim.start()
      else blinkAnim.start()
    }
  }

  SequentialAnimation {
    id: blinkAnim
    NumberAnimation { target: root; property: "openness"; to: 0.06; duration: 70; easing.type: Easing.InQuad }
    NumberAnimation { target: root; property: "openness"; to: 1; duration: 120; easing.type: Easing.OutQuad }
  }

  SequentialAnimation {
    id: doubleBlinkAnim
    NumberAnimation { target: root; property: "openness"; to: 0.06; duration: 60 }
    NumberAnimation { target: root; property: "openness"; to: 1; duration: 90 }
    PauseAnimation { duration: 90 }
    NumberAnimation { target: root; property: "openness"; to: 0.06; duration: 60 }
    NumberAnimation { target: root; property: "openness"; to: 1; duration: 110 }
  }

  // Walk away for two minutes and he curls up; move the mouse to wake him.
  Timer {
    interval: 1000
    repeat: true
    running: root.present && !root.sleeping
    onTriggered: {
      if (root.bubbleOpen || root.hovered || root.anyRunning()) return
      if (Date.now() - root.lastMoveAt > 120000) root.fallAsleep()
    }
  }

  // Idling the way the Office Assistant did it: leave him alone after you
  // dealt with him, then small things now and then, and the big numbers only
  // once he has been ignored for a while.
  property real lastInteractionAt: Date.now()
  readonly property var smallIdles: ["look", "brows", "tap", "glasses"]
  readonly property var bigIdles: ["atom", "pile", "music", "scratch", "bang", "flip"]

  function interacted() {
    root.lastInteractionAt = Date.now()
  }

  function pick(list) {
    return list[Math.floor(Math.random() * list.length)]
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.present && !root.sleeping
    onTriggered: {
      interval = 60000 + Math.random() * 60000
      if (root.bubbleOpen || root.hovered || root.anyRunning()) return
      var quiet = Date.now() - root.lastInteractionAt
      if (quiet < 180000) return
      var roll = Math.random()
      if (quiet > 600000 && roll < 0.3) root.play(root.pick(root.bigIdles))
      else if (roll < 0.6) root.play(root.pick(root.smallIdles))
    }
  }

  // Idle sway around his feet, and a slow breath.
  SequentialAnimation {
    running: root.present && !root.sleeping
    loops: Animation.Infinite
    NumberAnimation { target: sway; property: "angle"; to: 1.8; duration: 1700; easing.type: Easing.InOutSine }
    NumberAnimation { target: sway; property: "angle"; to: -1.8; duration: 3400; easing.type: Easing.InOutSine }
    NumberAnimation { target: sway; property: "angle"; to: 0; duration: 1700; easing.type: Easing.InOutSine }
  }

  SequentialAnimation {
    running: root.present
    loops: Animation.Infinite
    NumberAnimation { target: breathe; property: "yScale"; to: root.sleeping ? 0.97 : 1.02; duration: root.sleeping ? 2200 : 1400; easing.type: Easing.InOutSine }
    NumberAnimation { target: breathe; property: "yScale"; to: 1; duration: root.sleeping ? 2200 : 1400; easing.type: Easing.InOutSine }
  }

  SequentialAnimation {
    id: hopAnim
    ParallelAnimation {
      NumberAnimation { target: action; property: "yScale"; to: 0.86; duration: 110; easing.type: Easing.OutQuad }
      NumberAnimation { target: action; property: "xScale"; to: 1.1; duration: 110; easing.type: Easing.OutQuad }
    }
    ParallelAnimation {
      NumberAnimation { target: lift; property: "y"; to: -root.px(26); duration: 230; easing.type: Easing.OutQuad }
      NumberAnimation { target: action; property: "yScale"; to: 1.08; duration: 160 }
      NumberAnimation { target: action; property: "xScale"; to: 0.94; duration: 160 }
      NumberAnimation { target: root; property: "browLift"; to: 1; duration: 160 }
    }
    ParallelAnimation {
      NumberAnimation { target: lift; property: "y"; to: 0; duration: 460; easing.type: Easing.OutBounce }
      NumberAnimation { target: action; property: "yScale"; to: 1; duration: 320; easing.type: Easing.OutBack }
      NumberAnimation { target: action; property: "xScale"; to: 1; duration: 320; easing.type: Easing.OutBack }
      NumberAnimation { target: root; property: "browLift"; to: 0; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // GetAttention: huge eyes, and two taps against the glass.
  SequentialAnimation {
    id: attentionAnim
    ParallelAnimation {
      // Brows scale with the eyes, so a small lift already reads as a big one.
      NumberAnimation { target: root; property: "browLift"; to: 0.4; duration: 180; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "eyeBoost"; to: 1.75; duration: 320; easing.type: Easing.OutBack }
    }
    SequentialAnimation {
      loops: 2
      ScriptAction { script: root.ripple = 0 }
      ParallelAnimation {
        NumberAnimation { target: action; property: "xScale"; to: 1.12; duration: 100; easing.type: Easing.OutQuad }
        NumberAnimation { target: action; property: "yScale"; to: 1.12; duration: 100; easing.type: Easing.OutQuad }
      }
      ParallelAnimation {
        NumberAnimation { target: action; property: "xScale"; to: 1; duration: 160; easing.type: Easing.InQuad }
        NumberAnimation { target: action; property: "yScale"; to: 1; duration: 160; easing.type: Easing.InQuad }
        NumberAnimation { target: root; property: "ripple"; from: 0; to: 1; duration: 520; easing.type: Easing.OutQuad }
      }
    }
    PauseAnimation { duration: 450 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "eyeBoost"; to: 1; duration: 420; easing.type: Easing.InOutQuad }
      NumberAnimation { target: root; property: "browLift"; to: 0; duration: 600; easing.type: Easing.InOutQuad }
    }
    ScriptAction { script: root.ripple = 0 }
  }

  SequentialAnimation {
    id: wiggleAnim
    NumberAnimation { target: shake; property: "angle"; to: -10; duration: 70 }
    NumberAnimation { target: shake; property: "angle"; to: 9; duration: 90 }
    NumberAnimation { target: shake; property: "angle"; to: -7; duration: 85 }
    NumberAnimation { target: shake; property: "angle"; to: 5; duration: 80 }
    NumberAnimation { target: shake; property: "angle"; to: -2.5; duration: 75 }
    NumberAnimation { target: shake; property: "angle"; to: 0; duration: 90 }
  }

  // Turn around to look behind him, then back.
  SequentialAnimation {
    id: flipAnim
    NumberAnimation { target: action; property: "xScale"; to: -1; duration: 300; easing.type: Easing.InOutSine }
    PauseAnimation { duration: 700 }
    NumberAnimation { target: action; property: "xScale"; to: 1; duration: 300; easing.type: Easing.InOutSine }
  }

  // IdleEyeBrowRaise.
  SequentialAnimation {
    id: browsAnim
    NumberAnimation { target: root; property: "browLift"; to: 1.1; duration: 160; easing.type: Easing.OutQuad }
    PauseAnimation { duration: 700 }
    NumberAnimation { target: root; property: "browLift"; to: 0; duration: 380; easing.type: Easing.InOutQuad }
  }

  // IdleSideToSide.
  SequentialAnimation {
    id: lookAnim
    ScriptAction { script: root.lookMode = "wander" }
    NumberAnimation { target: root; property: "wanderX"; to: -1; duration: 380; easing.type: Easing.OutQuad }
    PauseAnimation { duration: 650 }
    NumberAnimation { target: root; property: "wanderX"; to: 1; duration: 520; easing.type: Easing.InOutQuad }
    PauseAnimation { duration: 650 }
    NumberAnimation { target: root; property: "wanderX"; to: 0; duration: 300; easing.type: Easing.OutQuad }
    ScriptAction { script: if (root.lookMode === "wander") root.lookMode = "cursor" }
  }

  // IdleAtom: unroll into a ring, spin up into an atom with his eyes as
  // electrons, and roll back.
  SequentialAnimation {
    id: atomAnim
    ScriptAction { script: { root.phase = 0; root.beginMorph("ring") } }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 520; easing.type: Easing.InOutCubic }
    ScriptAction { script: root.beginMorph("atom") }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 520; easing.type: Easing.InOutCubic }
      NumberAnimation { target: root; property: "phase"; to: 0.25; duration: 520 }
    }
    NumberAnimation { target: root; property: "phase"; to: 1.35; duration: 2600 }
    ScriptAction { script: root.beginMorph("ring") }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 480; easing.type: Easing.InOutCubic }
      NumberAnimation { target: root; property: "phase"; to: 1.5; duration: 480 }
    }
    ScriptAction { script: root.beginMorph("clip") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 650; easing.type: Easing.OutBack }
    ScriptAction { script: root.resetRig() }
  }

  // IdleRopePile: collapse into a coil, peek around, spring back up.
  SequentialAnimation {
    id: pileAnim
    ScriptAction { script: root.beginMorph("pile") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 1000; easing.type: Easing.InOutCubic }
    PauseAnimation { duration: 500 }
    ScriptAction { script: root.lookMode = "wander" }
    NumberAnimation { target: root; property: "wanderX"; to: -1; duration: 350 }
    PauseAnimation { duration: 500 }
    NumberAnimation { target: root; property: "wanderX"; to: 1; duration: 450 }
    PauseAnimation { duration: 500 }
    NumberAnimation { target: root; property: "wanderX"; to: 0; duration: 250 }
    ScriptAction { script: { root.lookMode = "cursor"; root.beginMorph("clip") } }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 600; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
      NumberAnimation { target: root; property: "browLift"; to: 1.2; duration: 200 }
    }
    NumberAnimation { target: root; property: "browLift"; to: 0; duration: 500 }
    ScriptAction { script: root.resetRig() }
  }

  // Congratulate: a check mark.
  SequentialAnimation {
    id: checkAnim
    ScriptAction { script: root.beginMorph("check") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 560; easing.type: Easing.OutBack }
    PauseAnimation { duration: 1200 }
    ScriptAction { script: root.beginMorph("clip") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 560; easing.type: Easing.OutBack }
    ScriptAction { script: root.resetRig() }
  }

  // Wave: stretch up into an exclamation mark.
  SequentialAnimation {
    id: bangAnim
    ScriptAction { script: root.beginMorph("tall") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 260; easing.type: Easing.OutQuad }
    ScriptAction { script: root.beginMorph("bang") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 340; easing.type: Easing.OutBack }
    SequentialAnimation {
      loops: 2
      NumberAnimation { target: shake; property: "angle"; to: 6; duration: 140; easing.type: Easing.InOutSine }
      NumberAnimation { target: shake; property: "angle"; to: -6; duration: 180; easing.type: Easing.InOutSine }
    }
    NumberAnimation { target: shake; property: "angle"; to: 0; duration: 120 }
    PauseAnimation { duration: 350 }
    ScriptAction { script: root.beginMorph("clip") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 560; easing.type: Easing.OutBack }
    ScriptAction { script: root.resetRig() }
  }

  // GestureUp: point at the bubble.
  SequentialAnimation {
    id: pointAnim
    ScriptAction { script: { root.lookMode = "bubble"; root.beginMorph("point") } }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 460; easing.type: Easing.OutBack }
      NumberAnimation { target: root; property: "browLift"; to: 1; duration: 300 }
    }
    PauseAnimation { duration: 1500 }
    ScriptAction { script: { root.lookMode = "cursor"; root.beginMorph("clip") } }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 460; easing.type: Easing.InOutCubic }
      NumberAnimation { target: root; property: "browLift"; to: 0; duration: 460 }
    }
    ScriptAction { script: root.resetRig() }
  }

  // IdleHeadScratch.
  SequentialAnimation {
    id: scratchAnim
    ScriptAction { script: { root.phase = 0; root.beginMorph("scratch") } }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 380; easing.type: Easing.InOutCubic }
    ParallelAnimation {
      NumberAnimation { target: root; property: "phase"; to: 1; duration: 1500 }
      SequentialAnimation {
        NumberAnimation { target: root; property: "browLift"; to: 0.8; duration: 300 }
        PauseAnimation { duration: 900 }
        NumberAnimation { target: root; property: "browLift"; to: 0; duration: 300 }
      }
    }
    ScriptAction { script: root.beginMorph("clip") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 380; easing.type: Easing.InOutCubic }
    ScriptAction { script: root.resetRig() }
  }

  // IdleFingerTap.
  SequentialAnimation {
    id: tapAnim
    ScriptAction { script: { root.phase = 0; root.beginMorph("tap") } }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 300; easing.type: Easing.InOutCubic }
    NumberAnimation { target: root; property: "phase"; to: 1; duration: 1500 }
    ScriptAction { script: root.beginMorph("clip") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 320; easing.type: Easing.InOutCubic }
    ScriptAction { script: root.resetRig() }
  }

  // CheckingSomething: reading glasses on, a long look at the bubble.
  SequentialAnimation {
    id: glassesAnim
    NumberAnimation { target: root; property: "glasses"; to: 1; duration: 280; easing.type: Easing.OutBack }
    ScriptAction { script: root.lookMode = "wander" }
    NumberAnimation { target: root; property: "wanderX"; to: -0.8; duration: 500 }
    NumberAnimation { target: root; property: "wanderX"; to: 0.6; duration: 1400; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "wanderX"; to: -0.8; duration: 300 }
    NumberAnimation { target: root; property: "wanderX"; to: 0.6; duration: 1400; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "wanderX"; to: 0; duration: 300 }
    NumberAnimation { target: root; property: "browLift"; to: 1; duration: 200 }
    PauseAnimation { duration: 300 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "glasses"; to: 0; duration: 260 }
      NumberAnimation { target: root; property: "browLift"; to: 0; duration: 400 }
    }
    ScriptAction { script: if (root.lookMode === "wander") root.lookMode = "cursor" }
  }

  // Hearing: headphones on, nodding along.
  SequentialAnimation {
    id: musicAnim
    ScriptAction { script: root.phase = 0 }
    NumberAnimation { target: root; property: "headphones"; to: 1; duration: 300; easing.type: Easing.OutBack }
    ParallelAnimation {
      NumberAnimation { target: root; property: "phase"; to: 1; duration: 3600 }
      SequentialAnimation {
        loops: 6
        ParallelAnimation {
          NumberAnimation { target: shake; property: "angle"; to: 4; duration: 300; easing.type: Easing.InOutSine }
          NumberAnimation { target: action; property: "yScale"; to: 0.96; duration: 300; easing.type: Easing.InOutSine }
        }
        ParallelAnimation {
          NumberAnimation { target: shake; property: "angle"; to: -4; duration: 300; easing.type: Easing.InOutSine }
          NumberAnimation { target: action; property: "yScale"; to: 1.02; duration: 300; easing.type: Easing.InOutSine }
        }
      }
    }
    ParallelAnimation {
      NumberAnimation { target: shake; property: "angle"; to: 0; duration: 200 }
      NumberAnimation { target: action; property: "yScale"; to: 1; duration: 200 }
      NumberAnimation { target: root; property: "headphones"; to: 0; duration: 300 }
    }
    ScriptAction { script: root.phase = 0 }
  }

  // IdleSnooze: curl up into a pile.
  SequentialAnimation {
    id: sleepAnim
    ScriptAction { script: root.beginMorph("pile") }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 1600; easing.type: Easing.InOutCubic }
      NumberAnimation { target: root; property: "openness"; to: 0.07; duration: 1600; easing.type: Easing.InOutQuad }
      NumberAnimation { target: root; property: "browLift"; to: -0.6; duration: 1600 }
    }
  }

  SequentialAnimation {
    id: wakeAnim
    ParallelAnimation {
      NumberAnimation { target: root; property: "openness"; to: 1; duration: 110 }
      NumberAnimation { target: root; property: "browLift"; to: 1.3; duration: 110 }
      NumberAnimation { target: root; property: "eyeBoost"; to: 1.35; duration: 150; easing.type: Easing.OutBack }
    }
    ScriptAction { script: root.beginMorph("clip") }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
      NumberAnimation { target: root; property: "eyeBoost"; to: 1; duration: 520 }
    }
    ScriptAction { script: { root.resetRig(); root.play("hop") } }
  }

  // Greeting: ride in on a bicycle made of himself.
  SequentialAnimation {
    id: greetAnim
    ScriptAction {
      script: {
        for (var name in root.animations) root.animations[name].stop()
        lift.y = 0
        root.resetRig()
        root.shapeA = "bike"
        root.shapeB = "bike"
        root.ride = 170
        root.openness = 1
      }
    }
    PauseAnimation { duration: 300 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "ride"; to: 0; duration: 1800; easing.type: Easing.OutCubic }
      SequentialAnimation {
        loops: 5
        NumberAnimation { target: lift; property: "y"; to: -root.px(2); duration: 90 }
        NumberAnimation { target: lift; property: "y"; to: 0; duration: 90 }
      }
    }
    PauseAnimation { duration: 250 }
    ScriptAction { script: root.beginMorph("clip") }
    ParallelAnimation {
      NumberAnimation { target: root; property: "morph"; to: 1; duration: 700; easing.type: Easing.OutBack }
      NumberAnimation { target: root; property: "browLift"; to: 1.2; duration: 400 }
    }
    ScriptAction { script: { root.resetRig(); hopAnim.start() } }
  }

  // GoodBye: fold into the bicycle and ride off the edge of the screen.
  SequentialAnimation {
    id: byeAnim
    ScriptAction { script: root.beginMorph("bike") }
    NumberAnimation { target: root; property: "morph"; to: 1; duration: 650; easing.type: Easing.InOutCubic }
    PauseAnimation { duration: 300 }
    NumberAnimation { target: root; property: "ride"; to: 200; duration: 1500; easing.type: Easing.InCubic }
    ScriptAction { script: { root.present = false; root.resetRig() } }
  }

  // ------------------------------------------------------------------ IPC

  IpcHandler {
    target: "jankeesvw.clippy"
    function tip(): string { root.summon(); root.showTip("attention"); return "ok" }
    function show(): string { root.summon(); return "ok" }
    function hide(): string { root.goAway(); return "ok" }
    function toggle(): string {
      if (root.present && !byeAnim.running) root.goAway()
      else root.summon()
      return "ok"
    }
    function fidget(): string { root.flourish(); return "ok" }
    // Shows a bubble with your own title and text, e.g. from an agent hook.
    function say(title: string, text: string): string {
      root.summon()
      return root.say(title, text, []) ? "ok" : "empty text"
    }
    // The same, with one link button next to Later.
    function sayLink(title: string, text: string, label: string, url: string): string {
      var link = root.linkButton(label, url)
      if (!link) return "invalid link"
      root.summon()
      return root.say(title, text, [link]) ? "ok" : "empty text"
    }
    // The same, with two link buttons.
    function sayLinks(title: string, text: string, label1: string, url1: string, label2: string, url2: string): string {
      var first = root.linkButton(label1, url1)
      var second = root.linkButton(label2, url2)
      if (!first || !second) return "invalid link"
      root.summon()
      return root.say(title, text, [first, second]) ? "ok" : "empty text"
    }
    // Plays one named animation; anything outside the list is ignored.
    function animate(name: string): string {
      var key = String(name).slice(0, 16)
      if (!root.animations[key]) return "unknown"
      root.play(key)
      return "ok"
    }
    function ping(): string { return "ok" }
  }

  // ------------------------------------------------------------ the window

  component Eye: Item {
    id: eye
    property var anchor: null
    property bool isLeft: true
    readonly property real s: (anchor ? anchor.s : 1) * root.eyeBoost

    width: 22
    height: 26
    x: (anchor ? anchor.x : 0) - width / 2
    y: (anchor ? anchor.y : 0) - height / 2
    scale: s

    Rectangle {
      id: white
      anchors.centerIn: parent
      width: parent.width
      height: Math.max(2.2, parent.height * root.openness)
      radius: width / 2
      color: "#ffffff"
      border.color: root.wireDark
      border.width: 1.7
      clip: true

      Rectangle {
        id: pupil
        width: 9.5
        height: 9.5
        radius: width / 2
        color: "#15171b"
        readonly property real roamX: (eye.width - width) / 2 - 3
        readonly property real roamY: (eye.height - height) / 2 - 4
        readonly property var roll: root.pose.roll
        readonly property real dirX: roll !== undefined ? Math.cos(roll) * 0.9 : root.gaze(eye, 0)
        readonly property real dirY: roll !== undefined ? Math.sin(roll) * 0.9 : root.gaze(eye, 1)
        x: (white.width - width) / 2 + dirX * roamX
        y: (eye.height - height) / 2 - (eye.height - white.height) / 2 + dirY * roamY
        Behavior on x { enabled: pupil.roll === undefined; NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
        Behavior on y { enabled: pupil.roll === undefined; NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

        Rectangle {
          x: 2; y: 1.8
          width: 3; height: 3
          radius: 1.5
          color: "#ffffff"
        }
      }
    }

    // Brows sit on the eye so they follow it into every pose.
    Shape {
      anchors.fill: parent
      opacity: Math.max(0, Math.min(1, root.pose.brows)) * (eye.s > 1.4 && root.eyeBoost === 1 ? 0 : 1)
      preferredRendererType: Shape.CurveRenderer
      transform: Translate { y: -root.browLift * 4.5 - (root.hovered ? 1.5 : 0) }

      ShapePath {
        fillColor: "transparent"
        strokeColor: root.wireDark
        strokeWidth: 3.4
        capStyle: ShapePath.RoundCap
        PathSvg {
          path: root.sleeping
            ? (eye.isLeft ? "M0 -3 Q11 -2 22 -4" : "M0 -4 Q11 -2 22 -3")
            : (eye.isLeft ? "M-1 -5 Q10 -13 22 -8" : "M0 -8 Q12 -13 23 -5")
        }
      }
    }

    // CheckingSomething.
    Rectangle {
      anchors.centerIn: parent
      width: 30
      height: 30
      radius: 15
      color: "transparent"
      border.color: root.wireDark
      border.width: 2.6
      opacity: root.glasses
      scale: 0.7 + 0.3 * root.glasses
    }
  }

  component WirePath: ShapePath {
    fillColor: "transparent"
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    PathPolyline { path: root.wirePath }
  }

  component BubbleButton: Rectangle {
    id: button
    property string label: ""
    signal activated()

    implicitWidth: buttonLabel.implicitWidth + root.px(18)
    implicitHeight: buttonLabel.implicitHeight + root.px(8)
    width: implicitWidth
    height: implicitHeight
    radius: root.px(5)
    color: buttonArea.pressed ? root.paperPressed : (buttonArea.containsMouse ? root.paperHover : root.paper)
    border.color: root.ink
    border.width: Math.max(1, root.px(1))

    Text {
      id: buttonLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: button.label
      color: root.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.activated()
    }
  }

  PanelWindow {
    id: win
    screen: root.targetScreen
    visible: root.targetScreen !== null

    // The surface covers the whole output and never resizes, so Hyprland has
    // no layer animation to play. The mask keeps everything outside Clippy
    // and his bubble click-through.
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "jankeesvw-clippy"
    WlrLayershell.layer: WlrLayer.Top
    // No keyboard at all until you click him; see claimKeys().
    WlrLayershell.keyboardFocus: root.keysWanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    mask: Region {
      x: stage.x
      y: stage.y
      width: root.present && !root.ghost ? stage.width : 0
      height: root.present && !root.ghost ? stage.height : 0

      Region {
        intersection: Intersection.Combine
        x: bubble.x
        y: bubble.y
        width: bubble.visible ? bubble.width : 0
        height: bubble.visible ? bubble.height : 0
      }
    }

    // Clippy's hit box. Room above him for the hop.
    Item {
      id: stage
      width: Math.ceil(104 * root.artScale) + root.px(12)
      height: Math.ceil(168 * root.artScale) + root.px(34)
      x: Math.max(0, Math.min(win.width - width, win.width - width - root.posRight))
      y: Math.max(0, Math.min(win.height - height, win.height - height - root.posBottom))

      // A soft shadow where he stands. It stays on the ground while he hops
      // and rides along with the bicycle.
      Rectangle {
        readonly property real groundX: (stage.width - 104 * root.artScale) / 2
        x: groundX + (22 + root.ride) * root.artScale
        y: stage.height - 12 * root.artScale
        width: 62 * root.artScale
        height: 9 * root.artScale
        radius: height / 2
        color: "#000000"
        visible: root.present || byeAnim.running
        opacity: (root.ghost ? 0.06 : 0.22) * (1 - Math.min(1, -lift.y / root.px(40)))
      }

      Item {
        id: body
        width: 104 * root.artScale
        height: 168 * root.artScale
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        visible: root.present || byeAnim.running
        opacity: root.ghost ? 0.25 : 1
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutQuad } }

        transform: [
          Scale { id: breathe; origin.x: body.width / 2; origin.y: body.height * 0.9 },
          Scale { id: action; origin.x: body.width / 2; origin.y: body.height * 0.9 },
          Rotation { id: sway; origin.x: body.width / 2; origin.y: body.height * 0.9 },
          Rotation { id: shake; origin.x: body.width / 2; origin.y: body.height * 0.8 },
          Translate { id: lift }
        ]

        Item {
          id: art
          x: 2
          width: 100
          height: 168
          scale: root.artScale
          transformOrigin: Item.TopLeft

          // GetAttention: rings where he taps the glass.
          Repeater {
            model: 2
            Rectangle {
              required property int index
              readonly property real t: Math.max(0, root.ripple - index * 0.25)
              x: 50 - width / 2
              y: 70 - height / 2
              width: 30 + 90 * t
              height: width
              radius: width / 2
              color: "transparent"
              border.color: "#ffffff"
              border.width: 2.5
              opacity: root.ripple > 0 && root.ripple < 1 ? (1 - t) * 0.8 : 0
            }
          }

          // Shows that he has the keyboard: a rim of accent colour around the
          // wire itself, so it bends along with whatever shape he is in.
          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: root.selected && !root.dragging ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
            WirePath { strokeColor: Color.accent; strokeWidth: 13 }
          }

          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            WirePath { strokeColor: root.wireDark; strokeWidth: 8.5 }
            WirePath { strokeColor: root.wireMetal; strokeWidth: 5.2 }
          }

          Shape {
            x: -1.1
            y: -1.2
            width: parent.width
            height: parent.height
            opacity: 0.85
            preferredRendererType: Shape.CurveRenderer
            WirePath { strokeColor: root.wireShine; strokeWidth: 1.5 }
          }

          // Hearing: the headband goes behind the eyes, the cups in front.
          Shape {
            anchors.fill: parent
            opacity: root.headphones
            preferredRendererType: Shape.CurveRenderer
            readonly property var l: root.pose.l
            readonly property var r: root.pose.r

            ShapePath {
              fillColor: "transparent"
              strokeColor: "#1d1f24"
              strokeWidth: 4
              capStyle: ShapePath.RoundCap
              PathSvg {
                path: "M" + (root.pose.l.x - 15) + " " + (root.pose.l.y + 4)
                  + " Q" + ((root.pose.l.x + root.pose.r.x) / 2) + " " + (root.pose.l.y - 46)
                  + " " + (root.pose.r.x + 15) + " " + (root.pose.r.y + 4)
              }
            }
          }

          Eye { anchor: root.pose.l; isLeft: true }
          Eye { anchor: root.pose.r; isLeft: false }

          // Glasses bridge between the two lenses.
          Rectangle {
            x: root.pose.l.x + 14 * root.pose.l.s
            y: (root.pose.l.y + root.pose.r.y) / 2 - 1.5
            width: Math.max(0, root.pose.r.x - root.pose.l.x - 14 * (root.pose.l.s + root.pose.r.s))
            height: 2.6
            color: root.wireDark
            opacity: root.glasses
          }

          Repeater {
            model: [root.pose.l, root.pose.r]
            Item {
              required property var modelData
              required property int index
              opacity: root.headphones
              x: modelData.x + (index === 0 ? -19 : 12)
              y: modelData.y - 8

              Rectangle {
                width: 8; height: 17
                radius: 3.5
                color: "#1d1f24"
              }

              Text {
                x: index === 0 ? -12 : 10
                y: -1
                textFormat: Text.PlainText
                text: index === 0 ? "((" : "))"
                color: "#ffffff"
                style: Text.Outline
                styleColor: root.wireDark
                font.family: Style.font.family
                font.pixelSize: 11
                font.bold: true
                opacity: 0.5 + 0.5 * Math.sin(root.phase * Math.PI * 24)
              }
            }
          }
        }
      }

      // Zzz while he sleeps.
      Item {
        id: snore
        anchors.fill: parent
        visible: root.sleeping
        property real phase: 0
        NumberAnimation on phase {
          from: 0; to: 1
          duration: 2600
          loops: Animation.Infinite
          running: root.sleeping
        }

        Repeater {
          model: 3
          Text {
            required property int index
            readonly property real p: (snore.phase + index / 3) % 1
            textFormat: Text.PlainText
            text: "z"
            font.family: Style.font.family
            font.bold: true
            font.pixelSize: root.px(11 + index * 3)
            color: "#ffffff"
            style: Text.Outline
            styleColor: root.wireDark
            x: stage.width * 0.62 + p * root.px(18)
            y: stage.height - 168 * root.artScale + 92 * root.artScale - p * root.px(44)
            opacity: p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85
          }
        }
      }

      // Click for a tip, drag to move him. Super+drag grabs him straight
      // away, the way it grabs a window.
      MouseArea {
        id: grab
        anchors.fill: parent
        enabled: root.present
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

        property real startX: 0
        property real startY: 0
        property real lastX: 0
        property int startRight: 0
        property int startBottom: 0
        property bool moved: false

        onContainsMouseChanged: root.hovered = containsMouse
        onPressed: function(mouse) {
          var p = mapToItem(null, mouse.x, mouse.y)
          startX = p.x
          startY = p.y
          lastX = p.x
          startRight = root.posRight
          startBottom = root.posBottom
          moved = false
          root.claimKeys()
          if (mouse.button === Qt.LeftButton && (mouse.modifiers & Qt.MetaModifier)) root.beginDrag()
        }
        onPositionChanged: function(mouse) {
          if (!pressed || !(pressedButtons & Qt.LeftButton)) return
          var p = mapToItem(null, mouse.x, mouse.y)
          var dx = p.x - startX, dy = p.y - startY
          if (!root.dragging && Math.abs(dx) + Math.abs(dy) > root.px(6)) root.beginDrag()
          if (!root.dragging) return
          root.moveTo(startRight - dx, startBottom - dy)
          // Swing a little in the direction he is carried.
          shake.angle = Math.max(-20, Math.min(20, shake.angle * 0.7 + (p.x - lastX) * 0.9))
          lastX = p.x
        }
        onReleased: if (root.dragging) root.endDrag()
        onCanceled: if (root.dragging) root.endDrag()
        onClicked: function(mouse) {
          if (moved) return
          if (mouse.button === Qt.RightButton) root.askGoodbye()
          else root.showTip(root.tipReaction())
        }
      }

      Item {
        id: keyTarget
        focus: true
        Keys.onPressed: function(event) {
          if (!root.keysWanted) return
          keyRelease.restart()
          var step = (event.modifiers & Qt.ShiftModifier) ? root.px(80) : root.px(16)
          switch (event.key) {
          case Qt.Key_Escape:
            if (root.bubbleOpen) root.closeBubble()
            else root.deselect()
            break
          case Qt.Key_W:
          case Qt.Key_Delete:
          case Qt.Key_Backspace:
            root.deselect()
            root.goAway()
            break
          case Qt.Key_Return:
          case Qt.Key_Enter:
          case Qt.Key_Space:
          case Qt.Key_T:
            root.showTip(root.tipReaction())
            break
          case Qt.Key_Left: root.nudge(-step, 0); break
          case Qt.Key_Right: root.nudge(step, 0); break
          case Qt.Key_Up: root.nudge(0, -step); break
          case Qt.Key_Down: root.nudge(0, step); break
          default:
            return
          }
          event.accepted = true
        }
      }
    }

    // ------------------------------------------------------------- bubble

    Rectangle {
      id: bubble
      readonly property int pad: root.px(12)

      width: root.px(330)
      height: bubbleColumn.implicitHeight + pad * 2
      x: Math.max(root.px(8), Math.min(stage.x + stage.width - width + root.px(6), win.width - width - root.px(8)))
      // Above him, unless he has been dragged too close to the top.
      readonly property bool below: stage.y + root.px(22) - height - tail.height < root.px(8)
      y: below ? stage.y + stage.height + tail.height - root.px(4) : stage.y + root.px(22) - height - tail.height

      color: root.paper
      border.color: root.ink
      border.width: Math.max(1, root.px(1))
      radius: root.px(10)

      opacity: root.bubbleOpen ? 1 : 0
      visible: opacity > 0.01
      scale: root.bubbleOpen ? 1 : 0.92
      transformOrigin: below ? Item.TopRight : Item.BottomRight
      Behavior on opacity { NumberAnimation { duration: 160 } }
      Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }

      HoverHandler {
        id: bubbleHover
        onHoveredChanged: {
          if (hovered) autoHide.stop()
          else if (root.bubbleOpen) autoHide.restart()
        }
      }

      // The tail points down at Clippy's head.
      Shape {
        id: tail
        width: root.px(22)
        height: root.px(14)
        x: Math.max(bubble.radius, Math.min(bubble.width - bubble.radius - width,
                    stage.x + stage.width / 2 - bubble.x - width / 2 - root.px(4)))
        y: bubble.below ? -height + bubble.border.width : bubble.height - bubble.border.width
        rotation: bubble.below ? 180 : 0
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillColor: root.paper
          strokeColor: root.ink
          strokeWidth: bubble.border.width
          joinStyle: ShapePath.RoundJoin
          startX: 0; startY: 0
          PathLine { x: tail.width * 0.62; y: tail.height }
          PathLine { x: tail.width; y: 0 }
        }
      }

      Rectangle {
        x: tail.x + bubble.border.width
        y: bubble.below ? 0 : bubble.height - bubble.border.width * 2
        width: tail.width - bubble.border.width * 2
        height: bubble.border.width * 2
        color: root.paper
      }

      Column {
        id: bubbleColumn
        x: bubble.pad
        y: bubble.pad
        width: bubble.width - bubble.pad * 2
        spacing: root.px(8)

        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, closeButton.height)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.right: closeButton.left
            anchors.rightMargin: root.px(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.bubbleTitle
            wrapMode: Text.WordWrap
            color: root.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            id: closeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "×"
            color: closeArea.containsMouse ? root.ink : root.inkSoft
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true

            MouseArea {
              id: closeArea
              anchors.fill: parent
              anchors.margins: -root.px(6)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeBubble()
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: root.bubbleBody
          wrapMode: Text.Wrap
          color: root.ink
          lineHeight: 1.12
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
        }

        Text {
          width: parent.width
          visible: root.bubbleKind === "tip" && root.tip !== null
          textFormat: Text.PlainText
          text: root.tip ? (root.tip.page + (root.tip.section ? " · " + root.tip.section : "")) : ""
          elide: Text.ElideRight
          color: root.inkSoft
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Item {
          width: parent.width
          height: buttons.height

          Row {
            id: buttons
            anchors.right: parent.right
            spacing: root.px(6)

            BubbleButton {
              label: root.bubbleKind === "tip" ? "Open manual"
                : root.bubbleKind === "agent" ? (root.agentLinks.length > 0 ? root.agentLinks[0].label : "Nice!")
                : root.bubbleKind === "goodbye" ? "Ride off" : "Show me a tip"
              onActivated: root.primaryAction()
            }

            BubbleButton {
              label: root.bubbleKind === "tip" ? "Next tip"
                : root.bubbleKind === "agent" && root.agentLinks.length > 1 ? root.agentLinks[1].label
                : root.bubbleKind === "goodbye" ? "Stay" : "Later"
              onActivated: root.secondaryAction()
            }
          }
        }
      }
    }
  }
}
