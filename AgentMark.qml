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
      case "claude":  drawBurst(ctx, c, s);  break
      case "codex":   drawHex(ctx, c, s);    break
      case "pi":      drawPi(ctx, c, s);     break
      default:        drawDot(ctx, c, s);    break
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

  // Anything we don't have a mark for: a neutral dot, never a wrong logo.
  function drawDot(ctx, c, s) {
    ctx.beginPath()
    ctx.arc(c, c, s * 0.17, 0, Math.PI * 2)
    ctx.stroke()
  }
}
