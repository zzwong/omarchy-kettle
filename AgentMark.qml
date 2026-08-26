import QtQuick

// Per-agent identity mark, drawn rather than glyphed.
//
// Nerd Fonts have no Anthropic or OpenAI glyph, and shipping a font would be
// absurd for three shapes. These are deliberately simplified line marks that
// read at 14px in a bar panel — recognisable as the agent, not pixel-accurate
// reproductions of anyone's trademark.
//
// The mark answers "who", the state glyph beside it answers "what". Keeping
// them separate is what lets state stay glyph-first for colourblind safety
// while still identifying the agent at a glance.
Canvas {
  id: root

  property string agent: ""
  property color stroke: "white"
  property real weight: Math.max(1.4, width * 0.115)

  implicitWidth: 14
  implicitHeight: 14

  onAgentChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onWidthChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var s = Math.min(width, height)
    var c = s / 2

    ctx.strokeStyle = root.stroke
    ctx.lineWidth = root.weight
    ctx.lineCap = "round"
    ctx.lineJoin = "round"

    switch (root.agent) {
      case "claude":     drawBurst(ctx, c, s);    break
      case "codex":      drawHex(ctx, c, s);      break
      case "pi":         drawPi(ctx, c, s);       break
      case "gemini":     drawSparkle(ctx, c, s);  break
      case "cursor":     drawCube(ctx, c, s);     break
      case "opencode":   drawFrame(ctx, c, s);    break
      case "copilot":    drawGoggles(ctx, c, s);  break
      case "grok":       drawOrbit(ctx, c, s);    break
      case "amp":        drawChevrons(ctx, c, s); break
      case "cline":      drawBot(ctx, c, s);      break
      case "kiro":       drawGhost(ctx, c, s);    break
      case "kimi":       drawKTick(ctx, c, s);    break
      case "droid":      drawFan(ctx, c, s);      break
      case "kilo":       drawPixels(ctx, c, s);   break
      case "agy":        drawArch(ctx, c, s);     break
      case "maki":       drawRoll(ctx, c, s);     break
      case "qwen":       drawKnot(ctx, c, s);     break
      // devin, hermes, qodercli, omp, mastracode: their logos are illegible
      // or ambiguous at 14px (per the collision survey and a render test), so
      // they keep the letterform.
      default:           drawLetter(ctx, c, s);   break
    }
  }

  // Anthropic's mark reduced to its essential: a radiating burst.
  function drawBurst(ctx, c, s) {
    var r = s * 0.36
    ctx.beginPath()
    for (var i = 0; i < 3; i++) {
      var a = (Math.PI / 3) * i - Math.PI / 2
      ctx.moveTo(c + Math.cos(a) * r, c + Math.sin(a) * r)
      ctx.lineTo(c - Math.cos(a) * r, c - Math.sin(a) * r)
    }
    ctx.stroke()
  }

  // OpenAI's knot suggested by a hexagon with an interior fork.
  function drawHex(ctx, c, s) {
    var r = s * 0.38
    ctx.beginPath()
    for (var i = 0; i < 6; i++) {
      var a = (Math.PI / 3) * i - Math.PI / 2
      var x = c + Math.cos(a) * r, y = c + Math.sin(a) * r
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
    }
    ctx.closePath()
    ctx.stroke()

    ctx.beginPath()
    ctx.lineWidth = root.weight * 0.85
    ctx.moveTo(c - r * 0.5, c - r * 0.26)
    ctx.lineTo(c, c)
    ctx.lineTo(c, c + r * 0.62)
    ctx.moveTo(c + r * 0.5, c - r * 0.26)
    ctx.lineTo(c, c)
    ctx.stroke()
  }

  // π, drawn rather than typed so it matches the others' weight and metrics.
  function drawPi(ctx, c, s) {
    var w = s * 0.34, top = c - s * 0.26, bot = c + s * 0.30
    ctx.beginPath()
    ctx.moveTo(c - w, top)
    ctx.lineTo(c + w, top)
    ctx.moveTo(c - w * 0.45, top)
    ctx.lineTo(c - w * 0.62, bot)
    ctx.moveTo(c + w * 0.5, top)
    ctx.lineTo(c + w * 0.5, bot - s * 0.09)
    ctx.quadraticCurveTo(c + w * 0.5, bot, c + w, bot * 0.985)
    ctx.stroke()
  }

  // Google Gemini: four-point sparkle, edges pinched toward the center.
  function drawSparkle(ctx, c, s) {
    var r = s * 0.44, k = s * 0.09
    ctx.beginPath()
    ctx.moveTo(c, c - r)
    ctx.quadraticCurveTo(c + k, c - k, c + r, c)
    ctx.quadraticCurveTo(c + k, c + k, c, c + r)
    ctx.quadraticCurveTo(c - k, c + k, c - r, c)
    ctx.quadraticCurveTo(c - k, c - k, c, c - r)
    ctx.closePath()
    ctx.stroke()
  }

  // Cursor: isometric cube with one facet filled — the shading is what keeps
  // it from reading as codex's wireframe hexagon at 14px.
  function drawCube(ctx, c, s) {
    var r = s * 0.40
    function v(i) {
      var a = (Math.PI / 3) * i - Math.PI / 2
      return [c + Math.cos(a) * r, c + Math.sin(a) * r]
    }
    ctx.beginPath()
    for (var i = 0; i < 6; i++) {
      var p = v(i)
      i === 0 ? ctx.moveTo(p[0], p[1]) : ctx.lineTo(p[0], p[1])
    }
    ctx.closePath()
    for (var j = 1; j < 6; j += 2) {
      var q = v(j)
      ctx.moveTo(c, c)
      ctx.lineTo(q[0], q[1])
    }
    ctx.stroke()
    var a3 = v(3), a5 = v(5)
    ctx.beginPath()
    ctx.moveTo(c, c)
    ctx.lineTo(a3[0], a3[1])
    ctx.lineTo(v(4)[0], v(4)[1])
    ctx.lineTo(a5[0], a5[1])
    ctx.closePath()
    ctx.fillStyle = root.stroke
    ctx.fill()
  }

  // opencode: a terminal window — square frame with an inner pane.
  function drawFrame(ctx, c, s) {
    var r = s * 0.40
    ctx.strokeRect(c - r, c - r, r * 2, r * 2)
    ctx.strokeRect(c - s * 0.16, c - s * 0.10, s * 0.32, s * 0.26)
  }

  // GitHub Copilot: the goggles — two lenses under one brow.
  function drawGoggles(ctx, c, s) {
    var e = s * 0.17, dx = s * 0.19
    ctx.beginPath()
    ctx.arc(c - dx, c + s * 0.06, e, 0, Math.PI * 2)
    ctx.moveTo(c + dx + e, c + s * 0.06)
    ctx.arc(c + dx, c + s * 0.06, e, 0, Math.PI * 2)
    ctx.moveTo(c - dx - e, c - s * 0.22)
    ctx.quadraticCurveTo(c, c - s * 0.40, c + dx + e, c - s * 0.22)
    ctx.stroke()
  }

  // Grok: an orbit ring pierced by a diagonal streak.
  function drawOrbit(ctx, c, s) {
    ctx.beginPath()
    ctx.arc(c, c, s * 0.34, 0, Math.PI * 2)
    ctx.moveTo(c - s * 0.46, c + s * 0.46)
    ctx.lineTo(c + s * 0.46, c - s * 0.46)
    ctx.stroke()
  }

  // Amp: three chevrons cascading up the diagonal.
  function drawChevrons(ctx, c, s) {
    ctx.save()
    ctx.translate(c, c)
    ctx.rotate(-Math.PI / 4)
    var w = s * 0.14, h = s * 0.22
    ctx.beginPath()
    for (var i = -1; i <= 1; i++) {
      var x = i * s * 0.26
      ctx.moveTo(x - w, -h)
      ctx.lineTo(x + w, 0)
      ctx.lineTo(x - w, h)
    }
    ctx.stroke()
    ctx.restore()
  }

  // Cline: robot head — box, two pill eyes, an antenna.
  function drawBot(ctx, c, s) {
    var w = s * 0.36, h = s * 0.26, top = c + s * 0.02
    ctx.strokeRect(c - w, top - h, w * 2, h * 2)
    ctx.beginPath()
    ctx.moveTo(c - s * 0.15, top - s * 0.08); ctx.lineTo(c - s * 0.15, top + s * 0.08)
    ctx.moveTo(c + s * 0.15, top - s * 0.08); ctx.lineTo(c + s * 0.15, top + s * 0.08)
    ctx.moveTo(c, top - h); ctx.lineTo(c, top - h - s * 0.10)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(c, top - h - s * 0.16, s * 0.06, 0, Math.PI * 2)
    ctx.stroke()
  }

  // Kiro: the ghost — dome top, wavy hem, two eyes.
  function drawGhost(ctx, c, s) {
    var w = s * 0.36, top = c - s * 0.38, hem = c + s * 0.36
    ctx.beginPath()
    ctx.moveTo(c - w, hem)
    ctx.lineTo(c - w, c - s * 0.02)
    ctx.quadraticCurveTo(c - w, top, c, top)
    ctx.quadraticCurveTo(c + w, top, c + w, c - s * 0.02)
    ctx.lineTo(c + w, hem)
    ctx.quadraticCurveTo(c + w * 0.55, hem - s * 0.16, c + w * 0.28, hem)
    ctx.quadraticCurveTo(c, hem - s * 0.16, c - w * 0.30, hem)
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(c - s * 0.13, c - s * 0.12); ctx.lineTo(c - s * 0.13, c + s * 0.02)
    ctx.moveTo(c + s * 0.13, c - s * 0.12); ctx.lineTo(c + s * 0.13, c + s * 0.02)
    ctx.stroke()
  }

  // Kimi: a K with the brand's detached tick at the shoulder.
  function drawKTick(ctx, c, s) {
    var x = c - s * 0.24, top = c - s * 0.36, bot = c + s * 0.36
    ctx.beginPath()
    ctx.moveTo(x, top); ctx.lineTo(x, bot)
    ctx.moveTo(c + s * 0.16, top + s * 0.10); ctx.lineTo(x, c + s * 0.02)
    ctx.lineTo(c + s * 0.22, bot)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(c + s * 0.30, top + s * 0.02, s * 0.06, 0, Math.PI * 2)
    ctx.fillStyle = root.stroke
    ctx.fill()
  }

  // Factory droid: turbine — curved blades around a hub.
  function drawFan(ctx, c, s) {
    ctx.beginPath()
    for (var i = 0; i < 6; i++) {
      var a = (Math.PI / 3) * i
      var x1 = c + Math.cos(a) * s * 0.12, y1 = c + Math.sin(a) * s * 0.12
      var x2 = c + Math.cos(a + 0.7) * s * 0.44, y2 = c + Math.sin(a + 0.7) * s * 0.44
      var mx = c + Math.cos(a + 0.35) * s * 0.34, my = c + Math.sin(a + 0.35) * s * 0.34
      ctx.moveTo(x1, y1)
      ctx.quadraticCurveTo(mx, my, x2, y2)
    }
    ctx.stroke()
  }

  // Kilo: pixel blocks in a frame — the QR-ish wordmark reduced to texture.
  function drawPixels(ctx, c, s) {
    var r = s * 0.40
    ctx.strokeRect(c - r, c - r, r * 2, r * 2)
    ctx.fillStyle = root.stroke
    var p = s * 0.14
    ctx.fillRect(c - s * 0.24, c - s * 0.24, p, p)
    ctx.fillRect(c + s * 0.08, c - s * 0.24, p, p)
    ctx.fillRect(c - s * 0.08, c + s * 0.06, p, p)
  }

  // Antigravity: the single-stroke arch.
  function drawArch(ctx, c, s) {
    ctx.beginPath()
    ctx.moveTo(c - s * 0.42, c + s * 0.34)
    ctx.quadraticCurveTo(c, c - s * 0.62, c + s * 0.42, c + s * 0.34)
    ctx.stroke()
  }

  // maki: the roll in cross-section — nori ring, filling in the middle.
  function drawRoll(ctx, c, s) {
    ctx.beginPath()
    ctx.arc(c, c, s * 0.38, 0, Math.PI * 2)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(c, c, s * 0.13, 0, Math.PI * 2)
    ctx.fillStyle = root.stroke
    ctx.fill()
  }

  // Qwen: three chevrons in rotation around the center.
  function drawKnot(ctx, c, s) {
    ctx.beginPath()
    for (var i = 0; i < 3; i++) {
      var a = (Math.PI * 2 / 3) * i - Math.PI / 2
      var px = c + Math.cos(a) * s * 0.38, py = c + Math.sin(a) * s * 0.38
      var l = a + Math.PI * 0.78, r = a - Math.PI * 0.78
      ctx.moveTo(px + Math.cos(l) * s * 0.30, py + Math.sin(l) * s * 0.30)
      ctx.lineTo(px, py)
      ctx.lineTo(px + Math.cos(r) * s * 0.30, py + Math.sin(r) * s * 0.30)
    }
    ctx.stroke()
  }

  // Anything we don't have a mark for: its initial in a ring — identifiable
  // without ever being a wrong logo. The ring keeps single letters from
  // reading as stray text in the panel.
  function drawLetter(ctx, c, s) {
    var ch = String(root.agent || "?").charAt(0).toUpperCase()
    ctx.beginPath()
    ctx.arc(c, c, s * 0.44, 0, Math.PI * 2)
    ctx.lineWidth = root.weight * 0.8
    ctx.stroke()
    ctx.fillStyle = root.stroke
    ctx.font = "bold " + Math.round(s * 0.52) + "px monospace"
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillText(ch, c, c + s * 0.03)
  }
}
