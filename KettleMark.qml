import QtQuick

// The bar icon: a pot, drawn rather than glyphed.
//
// `nf-md-coffee` was the obvious choice and it is wrong here. The glyph bakes
// in a saucer, which at bar size reads as a stray underline detached from the
// cup, and its body is small relative to the em box — so it sat high and
// looked shrunken beside the robot, bluetooth and wifi icons, which fill their
// vertical space evenly. Nothing saucer-free exists in JetBrainsMono Nerd
// Font, and shipping a font for one shape would be absurd.
//
// Drawing it means the optical weight matches the neighbours exactly, and the
// state variants share one silhouette instead of being five unrelated glyphs.
Canvas {
  id: root

  // simmering | needs-attention | ready | burnt | murky | idle
  property string potState: "idle"
  property color stroke: "white"

  // Measured against the neighbours: they paint ~16px of ink in this canvas.
  // Note `fill` cannot exceed 1 usefully — the Canvas is clamped to the icon
  // box, so overshooting clips instead of scaling. The lever is the SHAPE's
  // proportions below, which now span ~0.69 of `s` to land on 16px.
  readonly property real fill: 1.0
  property real weight: Math.max(1.5, width * 0.075)

  onPotStateChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onWidthChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()

    var s = Math.min(width, height) * fill
    var cx = width / 2
    // The body is anchored: it must not move when the state changes, and it
    // must not be lifted to make room for steam. Shifting it up for steam is
    // what made the mark read as sitting high — the eye aligns on the pot,
    // not on the ink extent that includes three thin wisps.
    var cy = height / 2 + s * 0.04

    ctx.strokeStyle = root.stroke
    ctx.fillStyle = root.stroke
    ctx.lineWidth = root.weight
    ctx.lineCap = "round"
    ctx.lineJoin = "round"

    drawPot(ctx, cx, cy, s)

    switch (root.potState) {
      case "simmering": drawSteam(ctx, cx, cy, s); break
      case "needs-attention": drawBang(ctx, cx, cy, s); break
      case "ready": drawTick(ctx, cx, cy, s); break
      case "burnt": drawCross(ctx, cx, cy, s); break
      case "murky": drawQuery(ctx, cx, cy, s); break
      default: break
    }
  }

  // A lid, a slightly tapered body, and a stubby handle. The taper and lid are
  // what make it read as a pot rather than a box — without them, at 15px and
  // with no steam showing, the idle state was just a rectangle.
  function drawPot(ctx, cx, cy, s) {
    var topW = s * 0.58, botW = s * 0.50
    var top = cy - s * 0.12, bot = cy + s * 0.33, r = s * 0.09

    ctx.beginPath()
    ctx.moveTo(cx - topW / 2, top)
    ctx.lineTo(cx + topW / 2, top)
    ctx.lineTo(cx + botW / 2, bot - r)
    ctx.quadraticCurveTo(cx + botW / 2, bot, cx + botW / 2 - r, bot)
    ctx.lineTo(cx - botW / 2 + r, bot)
    ctx.quadraticCurveTo(cx - botW / 2, bot, cx - botW / 2, bot - r)
    ctx.closePath()
    ctx.stroke()

    // Lid: slightly wider than the body, with a nub.
    var lidW = s * 0.66, lidY = top - s * 0.07
    ctx.beginPath()
    ctx.moveTo(cx - lidW / 2, lidY)
    ctx.lineTo(cx + lidW / 2, lidY)
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(cx, lidY)
    ctx.lineTo(cx, lidY - s * 0.08)
    ctx.stroke()

    // Handle on the right rim.
    ctx.beginPath()
    ctx.moveTo(cx + topW / 2, top + s * 0.10)
    ctx.lineTo(cx + topW / 2 + s * 0.11, top + s * 0.10)
    ctx.lineTo(cx + topW / 2 + s * 0.11, top + s * 0.21)
    ctx.stroke()
  }

  // Shorter than it was, because it now has to live in the headroom above a
  // fixed pot rather than shoving the pot down the canvas.
  function drawSteam(ctx, cx, cy, s) {
    var top = cy - s * 0.24
    ctx.lineWidth = root.weight * 0.8
    for (var i = -1; i <= 1; i++) {
      var x = cx + i * s * 0.17
      ctx.beginPath()
      ctx.moveTo(x, top)
      ctx.quadraticCurveTo(x + s * 0.07, top - s * 0.08, x, top - s * 0.17)
      ctx.stroke()
    }
  }

  // State marks sit inside the body so the silhouette never changes.
  function drawBang(ctx, cx, cy, s) {
    ctx.lineWidth = root.weight
    ctx.beginPath()
    ctx.moveTo(cx, cy + s * 0.02)
    ctx.lineTo(cx, cy + s * 0.16)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(cx, cy + s * 0.26, root.weight * 0.55, 0, Math.PI * 2)
    ctx.fill()
  }

  function drawTick(ctx, cx, cy, s) {
    ctx.lineWidth = root.weight
    ctx.beginPath()
    ctx.moveTo(cx - s * 0.15, cy + s * 0.12)
    ctx.lineTo(cx - s * 0.03, cy + s * 0.23)
    ctx.lineTo(cx + s * 0.17, cy + s * 0.01)
    ctx.stroke()
  }

  function drawCross(ctx, cx, cy, s) {
    ctx.lineWidth = root.weight
    var d = s * 0.13, my = cy + s * 0.14
    ctx.beginPath()
    ctx.moveTo(cx - d, my - d); ctx.lineTo(cx + d, my + d)
    ctx.moveTo(cx + d, my - d); ctx.lineTo(cx - d, my + d)
    ctx.stroke()
  }

  function drawQuery(ctx, cx, cy, s) {
    ctx.lineWidth = root.weight * 0.9
    ctx.beginPath()
    ctx.arc(cx, cy + s * 0.10, s * 0.09, Math.PI, Math.PI * 2.35)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(cx + s * 0.04, cy + s * 0.27, root.weight * 0.5, 0, Math.PI * 2)
    ctx.fill()
  }
}
