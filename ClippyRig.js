// Clippy's wire rig.
//
// The paperclip is one wire: a polyline of N points in a 100 x 168 design box.
// Every pose he can take (the clip itself, a bicycle, an atom, a pile of rope,
// a check mark, ...) is the same wire resampled to N points by arc length, so
// any two poses can be blended point by point. His eyes and brows ride along
// as anchors that are blended the same way.
.pragma library

var N = 220
var STEP = 1.2
var TAU = Math.PI * 2

function Path(x, y) {
  this.p = [{ x: x, y: y }]
}

Path.prototype.last = function() {
  return this.p[this.p.length - 1]
}

Path.prototype.line = function(x, y) {
  var l = this.last()
  var len = Math.sqrt((x - l.x) * (x - l.x) + (y - l.y) * (y - l.y))
  var n = Math.max(1, Math.ceil(len / STEP))
  for (var i = 1; i <= n; i++)
    this.p.push({ x: l.x + (x - l.x) * i / n, y: l.y + (y - l.y) * i / n })
  return this
}

// Angles are screen angles: 0 is right, PI/2 is down.
Path.prototype.arc = function(cx, cy, r, a0, a1) {
  var n = Math.max(2, Math.ceil(Math.abs(a1 - a0) * r / STEP))
  for (var i = 1; i <= n; i++) {
    var a = a0 + (a1 - a0) * i / n
    this.p.push({ x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) })
  }
  return this
}

function curve(fn, t0, t1, n) {
  var out = []
  for (var i = 0; i <= n; i++) out.push(fn(t0 + (t1 - t0) * i / n))
  return out
}

function resample(pts, n) {
  var dist = [0]
  for (var i = 1; i < pts.length; i++) {
    var dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y
    dist.push(dist[i - 1] + Math.sqrt(dx * dx + dy * dy))
  }
  var total = dist[dist.length - 1]
  var out = []
  var j = 0
  for (var k = 0; k < n; k++) {
    var target = total * k / (n - 1)
    while (j < dist.length - 2 && dist[j + 1] < target) j++
    var span = dist[j + 1] - dist[j]
    var t = span > 0 ? (target - dist[j]) / span : 0
    out.push({
      x: pts[j].x + (pts[j + 1].x - pts[j].x) * t,
      y: pts[j].y + (pts[j + 1].y - pts[j].y) * t
    })
  }
  return out
}

function eye(x, y, s) {
  return { x: x, y: y, s: s }
}

// The body of the clip up to the bottom of its outer loop. Poses that move
// only the free end of the wire start from here.
function clipBody() {
  return new Path(38, 62)
    .line(38, 120).arc(50, 120, 12, Math.PI, 0)
    .line(62, 36).arc(43, 36, 19, 0, -Math.PI)
    .line(24, 132).arc(50, 132, 26, Math.PI, 0)
}

function restEyes(shape) {
  shape.l = eye(33, 51, 1)
  shape.r = eye(60, 51, 1)
  return shape
}

var builders = {
  clip: function() {
    return restEyes({ pts: clipBody().line(76, 54).p, brows: 1 })
  },

  // Stretched tall and thin, on the way to an exclamation mark.
  tall: function() {
    var stretch = function(p) { return { x: 50 + (p.x - 50) * 0.86, y: 158 - (158 - p.y) * 1.22 } }
    var pts = clipBody().line(76, 54).p.map(stretch)
    var l = stretch({ x: 33, y: 51 }), r = stretch({ x: 60, y: 51 })
    return { pts: pts, l: eye(l.x, l.y, 0.95), r: eye(r.x, r.y, 0.95), brows: 1 }
  },

  // Wave: a tall loop with his eyes as the dot underneath.
  bang: function() {
    var pts = new Path(50, 118).line(41, 40).arc(50, 40, 9, Math.PI, TAU).line(50, 118).p
    return { pts: pts, l: eye(43, 140, 0.62), r: eye(57, 140, 0.62), brows: 0.3 }
  },

  // Congratulate: a check mark, drawn with a doubled wire like a real clip.
  check: function() {
    var pts = new Path(18, 100).line(38, 140).line(90, 32).line(85, 28).line(37, 128).line(25, 103).p
    return { pts: pts, l: eye(13, 138, 0.7), r: eye(29, 147, 0.7), brows: 1 }
  },

  // The halfway point between the clip and the atom.
  ring: function() {
    var pts = curve(function(t) {
      return { x: 50 + 36 * Math.cos(t), y: 104 + 36 * Math.sin(t) }
    }, -2.0, -2.0 - TAU * 1.15, 300)
    return { pts: pts, l: eye(14, 98, 0.7), r: eye(50, 104, 0.7), brows: 0 }
  },

  // IdleRopePile: collapsed into a coil with his eyes peeking over the top.
  pile: function() {
    var pts = curve(function(t) {
      var r = 28 - t * 0.8
      return { x: 50 + r * Math.cos(t), y: 152 - t * 1.3 + r * 0.3 * Math.sin(t) }
    }, 0, TAU * 4, 900)
    return { pts: pts, l: eye(42, 111, 0.85), r: eye(58, 111, 0.85), brows: 1 }
  },

  // Greeting and GoodBye: a bicycle whose wheels are his eyes.
  bike: function() {
    var pts = new Path(32, 100)
      .line(46, 100).line(40, 100).line(40, 108)
      .line(48, 134).line(24, 134).line(40, 108)
      .line(68, 108).line(48, 134).line(68, 108)
      .line(72, 94).line(66, 90).line(80, 90).line(72, 94)
      .line(78, 134).p
    return { pts: pts, l: eye(24, 134, 1.55), r: eye(78, 134, 1.55), brows: 0 }
  },

  // GestureUp: the free end shoots up past his head towards the bubble, with
  // a little crook at the tip like a finger.
  point: function() {
    var pts = clipBody().line(76, 12).arc(70, 12, 6, 0, -Math.PI * 0.75).p
    return restEyes({ pts: pts, brows: 1.2 })
  }
}

var cache = {}

function staticShape(name) {
  if (!cache[name]) {
    var shape = builders[name]()
    shape.pts = resample(shape.pts, N)
    cache[name] = shape
  }
  return cache[name]
}

function dynamicShape(name, phase, ride) {
  if (name === "atom") {
    // IdleAtom: a precessing ellipse that closes after three orbits, with his
    // eyes circling as electrons.
    var orbit = function(t) {
      var rot = t / 3 + phase * 1.2
      var ex = 40 * Math.cos(t), ey = 13 * Math.sin(t)
      return {
        x: 50 + ex * Math.cos(rot) - ey * Math.sin(rot),
        y: 104 + ex * Math.sin(rot) + ey * Math.cos(rot)
      }
    }
    var te = phase * TAU * 2.2
    var l = orbit(te), r = orbit(te + Math.PI * 3 + 1.3)
    return {
      pts: resample(curve(orbit, 0, Math.PI * 6, 700), N),
      l: eye(l.x, l.y, 0.6), r: eye(r.x, r.y, 0.6), brows: 0
    }
  }

  if (name === "scratch") {
    // IdleHeadScratch: the free end reaches over his head and rubs it.
    var rub = 0.5 + 0.5 * Math.sin(phase * TAU * 3)
    var pts = clipBody().line(76, 54).line(77, 40).arc(62, 40, 15, 0, -2.1 - 0.6 * rub).p
    return restEyes({ pts: resample(pts, N), brows: 1 })
  }

  if (name === "tap") {
    // IdleFingerTap: the free end taps the paper, impatiently.
    var lift = Math.abs(Math.sin(phase * Math.PI * 5))
    var tapPts = clipBody().line(76, 112).line(92, 152 - 12 * lift).p
    return restEyes({ pts: resample(tapPts, N), brows: 0.4 })
  }

  if (name === "bike") {
    var bike = staticShape("bike")
    return {
      pts: bike.pts.map(function(p) { return { x: p.x + ride, y: p.y } }),
      l: eye(bike.l.x + ride, bike.l.y, bike.l.s),
      r: eye(bike.r.x + ride, bike.r.y, bike.r.s),
      brows: 0,
      roll: ride / 17
    }
  }

  return staticShape(builders[name] ? name : "clip")
}

function lerp(a, b, t) {
  return a + (b - a) * t
}

// Blend pose `a` into pose `b`. `m` may overshoot past 0..1 for elastic
// easing. While the wire is between two poses it ripples a little, the way a
// real wire would.
function pose(a, b, m, phase, ride) {
  var A = dynamicShape(a, phase, ride)
  var B = dynamicShape(b, phase, ride)
  var pts = new Array(N)
  var amp = 2.4 * Math.sin(Math.PI * Math.max(0, Math.min(1, m)))

  for (var i = 0; i < N; i++) {
    pts[i] = { x: lerp(A.pts[i].x, B.pts[i].x, m), y: lerp(A.pts[i].y, B.pts[i].y, m) }
  }

  if (amp > 0.05) {
    var out = new Array(N)
    for (var j = 0; j < N; j++) {
      var prev = pts[Math.max(0, j - 1)], next = pts[Math.min(N - 1, j + 1)]
      var dx = next.x - prev.x, dy = next.y - prev.y
      var len = Math.sqrt(dx * dx + dy * dy) || 1
      var w = amp * Math.sin(j / N * Math.PI * 5 + m * 8)
      out[j] = { x: pts[j].x - dy / len * w, y: pts[j].y + dx / len * w }
    }
    pts = out
  }

  var roll = m < 0.5 ? A.roll : B.roll
  return {
    pts: pts,
    l: eye(lerp(A.l.x, B.l.x, m), lerp(A.l.y, B.l.y, m), lerp(A.l.s, B.l.s, m)),
    r: eye(lerp(A.r.x, B.r.x, m), lerp(A.r.y, B.r.y, m), lerp(A.r.s, B.r.s, m)),
    brows: lerp(A.brows, B.brows, m),
    roll: roll
  }
}
