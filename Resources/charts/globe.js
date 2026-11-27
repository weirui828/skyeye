import { flowPhase, flowRate, shortName } from './flow-style.js'

const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5))
export const SPHERE_RIM = 4.5 / Math.sqrt(4.5 ** 2 - 1)
const clamp = (value, low, high) => Math.max(low, Math.min(high, value))
const mix = (a, b, t) => a.map((v, i) => v * (1 - t) + b[i] * t)
const norm = v => Math.hypot(...v)
const rgb = value => { const n = parseInt(value.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255] }
const rgba = (value, alpha) => `rgba(${rgb(value).join(',')},${clamp(alpha, 0, 1)})`

export function sphereNodes(nodes, previous = []) {
  const result = []
  for (const remote of [false, true]) {
    const side = nodes.filter(n => (n.kind === 'remote') === remote).sort((a, b) => a.id.localeCompare(b.id))
    side.forEach((node, index) => {
      const x = remote ? -0.28 + 1.28 * (index + 0.5) / side.length : -1 + 0.72 * (index + 0.5) / side.length
      const angle = index * GOLDEN_ANGLE + (remote ? 0.7 : 0)
      const r = Math.sqrt(1 - x * x)
      result.push({ ...node, position: [x, Math.cos(angle) * r, Math.sin(angle) * r] })
    })
  }
  if (!previous.length) return result
  const remembered = new Map(previous.map(n => [n.id, n.position]))
  const placed = result.filter(n => remembered.has(n.id)).map(n => ({ ...n, position: remembered.get(n.id) }))
  for (const node of result.filter(n => !remembered.has(n.id))) {
    let best = node.position, score = -Infinity
    for (let i = 0; i < 96; i++) {
      const x = node.kind === 'remote' ? -0.28 + 1.28 * (i + 0.5) / 96 : -1 + 0.72 * (i + 0.5) / 96
      const r = Math.sqrt(1 - x * x), angle = i * GOLDEN_ANGLE
      const candidate = [x, r * Math.cos(angle), r * Math.sin(angle)]
      const clearance = Math.min(4, ...placed.map(n => norm(candidate.map((v, j) => v - n.position[j]))))
      if (clearance > score) { best = candidate; score = clearance }
    }
    placed.push({ ...node, position: best })
  }
  return placed
}

export function rotatePoint([x, y, z], yaw, pitch) {
  const nearX = x * Math.cos(yaw) + z * Math.sin(yaw)
  const nearZ = z * Math.cos(yaw) - x * Math.sin(yaw)
  return [nearX, y * Math.cos(pitch) - nearZ * Math.sin(pitch), y * Math.sin(pitch) + nearZ * Math.cos(pitch)]
}

export function projectPoint(point, { yaw = 0, pitch = 0, cx = 0, cy = 0, radius = 1 } = {}) {
  const [x, y, z] = rotatePoint(point, yaw, pitch)
  const perspective = 4.5 / (4.5 - z)
  return { x: cx + x * radius * perspective, y: cy + y * radius * perspective, z, scale: perspective }
}

export function sphereCurve(a, b, t, local = false) {
  let first, second
  if (norm(a.map((v, i) => v - b[i])) < 0.001) {
    const tangent = Math.abs(a[1]) < 0.9 ? [a[2], 0, -a[0]] : [0, -a[2], a[1]]
    const length = norm(tangent) || 1
    first = a.map((v, i) => v * 0.58 + tangent[i] / length * 0.25)
    second = a.map((v, i) => v * 0.58 - tangent[i] / length * 0.25)
  } else {
    const center = local ? [-0.58, 0, 0] : [0.03, 0, 0]
    first = mix(a, center, 0.68)
    second = mix(b, center, 0.68)
  }
  const u = 1 - t
  return a.map((value, i) => u ** 3 * value + 3 * u * u * t * first[i] + 3 * u * t * t * second[i] + t ** 3 * b[i])
}

export function frontSurface(u, v) {
  const d = 4.5, a = u * u + v * v + d * d
  const discriminant = d ** 4 - a * (d * d - 1)
  if (discriminant < 0) return null
  const t = (d * d - Math.sqrt(discriminant)) / a
  return [t * u, t * v, d * (1 - t)]
}

export function sphereLocalAt([x, y, z], yaw, pitch) {
  const nearZ = z * Math.cos(pitch) - y * Math.sin(pitch)
  return x * Math.cos(yaw) - nearZ * Math.sin(yaw) < -0.28
}

function shellTexture() {
  const size = 256, canvas = document.createElement('canvas')
  canvas.width = size; canvas.height = size
  const context = canvas.getContext('2d'), pixels = context.createImageData(size, size)
  const rays = []
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    let u = ((x + 0.5) / size * 2 - 1) * SPHERE_RIM, v = ((y + 0.5) / size * 2 - 1) * SPHERE_RIM
    if (Math.hypot(u, v) >= SPHERE_RIM * 0.999999) { const scale = SPHERE_RIM * 0.999999 / Math.hypot(u, v); u *= scale; v *= scale }
    const point = frontSurface(u, v)
    const [px, py, pz] = point
    const facing = Math.max(0, (4.5 * pz - 1) / Math.hypot(px, py, 4.5 - pz))
    const light = Math.max(0, -0.35 * px - 0.45 * py + 0.82 * pz)
    rays.push({ offset: (y * size + x) * 4, point,
      blend: 0.015 + (1 - light) * 0.025 + (1 - facing) ** 4 * 0.36,
      shine: Math.max(0, -0.28 * px - 0.38 * py + 0.88 * pz) ** 50 * 0.8 })
  }
  let stamp = -Infinity, key = ''
  return {
    draw(time, yaw, pitch, colors, dragging) {
      const palette = `${colors.card}${colors.local}${colors.accent}`
      if (time - stamp > (dragging ? 30 : 70) || palette !== key) {
        stamp = time; key = palette
        const base = rgb(colors.card), local = rgb(colors.local), remote = rgb(colors.accent)
        const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch)
        for (const ray of rays) {
          const [x, y, z] = ray.point
          const tint = x * cy - (z * cp - y * sp) * sy < -0.28 ? local : remote
          for (let channel = 0; channel < 3; channel++) {
            const color = base[channel] * (1 - ray.blend) + tint[channel] * ray.blend
            pixels.data[ray.offset + channel] = color + (255 - color) * ray.shine
          }
          pixels.data[ray.offset + 3] = 255
        }
        context.putImageData(pixels, 0, 0)
      }
      return canvas
    },
  }
}

function distanceToSegment(point, a, b) {
  const x = b.x - a.x, y = b.y - a.y
  const t = clamp(((point.x - a.x) * x + (point.y - a.y) * y) / (x * x + y * y || 1), 0, 1)
  return Math.hypot(point.x - a.x - t * x, point.y - a.y - t * y)
}

export function mountGlobe(canvas, { onSelect, onHover }) {
  const ctx = canvas.getContext('2d')
  let width = 800, height = 600, radius = 200, cx = 400, cy = 300
  let yaw = -0.16, pitch = -0.15, zoom = 1, orbit = true, lastTime = 0
  let nodes = [], links = [], chosen = null, hits = [], wires = [], pointer = null, disposed = false
  let palette = null, colors = {}, graphAt = 0
  const parent = canvas.closest('.monitoring-root')
  const material = shellTexture()
  const listeners = []
  const listen = (event, handler, options) => { canvas.addEventListener(event, handler, options); listeners.push([event, handler, options]) }
  const project = point => projectPoint(point, { yaw, pitch, cx, cy, radius: radius * zoom })
  const localColor = node => node.kind === 'remote' ? colors.accent : colors.ink

  function hit(point) {
    const candidates = hits.filter(n => Math.hypot(n.screen.x - point.x, n.screen.y - point.y) < 10)
      .sort((a, b) => b.screen.z - a.screen.z)
    if (candidates.length) return candidates[0].id
    let nearest = null, distance = 5
    for (const wire of wires) {
      for (let i = 1; i < wire.points.length; i++) {
        const d = distanceToSegment(point, wire.points[i - 1], wire.points[i])
        if (d < distance) { distance = d; nearest = wire.id }
      }
    }
    return nearest
  }

  function coords(event) {
    const rect = canvas.getBoundingClientRect()
    return { x: (event.clientX - rect.left) * width / rect.width, y: (event.clientY - rect.top) * height / rect.height }
  }

  listen('pointerdown', event => {
    if (event.button !== 0) return
    const p = coords(event)
    pointer = { id: event.pointerId, x: p.x, y: p.y, startX: p.x, startY: p.y, moved: false }
    canvas.setPointerCapture(event.pointerId)
    canvas.focus({ preventScroll: true })
    onHover(null)
  })
  listen('pointermove', event => {
    const p = coords(event)
    if (pointer) {
      if (Math.hypot(p.x - pointer.startX, p.y - pointer.startY) > 4) pointer.moved = true
      if (pointer.moved) {
        yaw += (p.x - pointer.x) * 0.006
        pitch = clamp(pitch + (p.y - pointer.y) * 0.006, -Math.PI / 2, Math.PI / 2)
        canvas.style.cursor = 'grabbing'
      }
      pointer.x = p.x; pointer.y = p.y
    } else {
      const id = hit(p)
      onHover(id)
      canvas.style.cursor = id ? 'pointer' : 'grab'
    }
  })
  listen('pointerup', event => {
    if (!pointer || event.pointerId !== pointer.id) return
    const moved = pointer.moved
    pointer = null
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId)
    canvas.style.cursor = 'grab'
    if (!moved) onSelect(hit(coords(event)))
  })
  listen('pointercancel', () => { pointer = null; canvas.style.cursor = 'grab' })
  listen('pointerleave', () => { if (!pointer) onHover(null) })
  listen('wheel', event => { event.preventDefault(); zoom = clamp(zoom * Math.exp(-event.deltaY * 0.001), 0.7, 1.45) }, { passive: false })
  listen('keydown', event => {
    const actions = { ArrowLeft: () => yaw -= 0.12, ArrowRight: () => yaw += 0.12,
      ArrowUp: () => pitch = clamp(pitch - 0.12, -Math.PI / 2, Math.PI / 2),
      ArrowDown: () => pitch = clamp(pitch + 0.12, -Math.PI / 2, Math.PI / 2),
      Home: reset, Escape: () => onSelect(null), '+': () => zoom = Math.min(1.45, zoom * 1.1), '-': () => zoom = Math.max(0.7, zoom / 1.1) }
    if (!Object.hasOwn(actions, event.key)) return
    event.preventDefault(); actions[event.key]()
  })

  function reset() { yaw = -0.16; pitch = -0.15; zoom = 1 }

  function stroke(points, color, opacity, weight = 1) {
    if (points.length < 2) return
    ctx.beginPath(); ctx.moveTo(points[0].x, points[0].y)
    for (const p of points.slice(1)) ctx.lineTo(p.x, p.y)
    ctx.strokeStyle = color; ctx.globalAlpha = opacity; ctx.lineWidth = weight; ctx.stroke()
  }

  function draw(time, { fresh, warmingUp, reducedMotion }) {
    if (disposed || canvas.hidden) { lastTime = time; return }
    if (orbit && !reducedMotion && !pointer && lastTime) yaw += Math.min(60, time - lastTime) * 0.000024
    lastTime = time
    if (palette !== parent.dataset.palette) {
      palette = parent.dataset.palette
      const style = getComputedStyle(parent)
      colors = Object.fromEntries(['card', 'ink', 'muted', 'accent', 'local', 'thread', 'edge'].map(key => [key, style.getPropertyValue(`--${key}`).trim()]))
    }
    const ratio = Math.min(2, window.devicePixelRatio || 1)
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
      canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio)
    }
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.clearRect(0, 0, width, height)
    ctx.lineCap = 'round'; ctx.lineJoin = 'round'
    const r = radius * zoom * SPHERE_RIM
    const shadow = ctx.createRadialGradient(cx, cy + r + 14, 0, cx, cy + r + 14, r * 0.7)
    shadow.addColorStop(0, 'rgba(45, 56, 65, 0.09)'); shadow.addColorStop(1, 'rgba(45, 56, 65, 0)')
    ctx.save(); ctx.translate(0, (cy + r + 14) * 0.89); ctx.scale(1, 0.11)
    ctx.fillStyle = shadow; ctx.globalAlpha = 0.8; ctx.fillRect(cx - r, cy + r - r, r * 2, r * 2); ctx.restore()
    ctx.globalAlpha = 1
    ctx.save(); ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.clip()
    ctx.drawImage(material.draw(time, yaw, pitch, colors, Boolean(pointer)), cx - r, cy - r, r * 2, r * 2)
    ctx.restore()
    ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2)
    ctx.strokeStyle = colors.thread; ctx.globalAlpha = 0.25; ctx.lineWidth = 0.65; ctx.stroke()

    const seam = Array.from({ length: 121 }, (_, i) => {
      const angle = i / 120 * Math.PI * 2, rr = Math.sqrt(1 - 0.28 ** 2)
      return project([-0.28, Math.cos(angle) * rr, Math.sin(angle) * rr])
    })
    for (let i = 1; i < seam.length; i++) stroke(seam.slice(i - 1, i + 1), colors.local, seam[i].z > 0.2 ? 0.23 : 0.055, 0.7)

    const lookup = new Map(nodes.map(n => [n.id, n]))
    const selectedLink = links.find(l => l.id === chosen)
    const related = new Set(selectedLink ? [selectedLink.from, selectedLink.to] : chosen ? [chosen] : [])
    const loads = new Map()
    for (const l of links) {
      if (l.from === chosen || l.to === chosen) { related.add(l.from); related.add(l.to) }
      for (const id of [l.from, l.to]) loads.set(id, (loads.get(id) ?? 0) + flowRate(l))
    }
    const maximum = Math.max(1, ...links.map(flowRate))
    wires = []
    const projectedLinks = links.map(link => {
      const a = lookup.get(link.from), b = lookup.get(link.to)
      if (!a || !b) return null
      const points = Array.from({ length: 49 }, (_, i) => project(sphereCurve(a.position, b.position, i / 48, link.local)))
      return { ...link, a, b, points, depth: points.reduce((sum, p) => sum + p.z, 0) / points.length }
    }).filter(Boolean).sort((a, b) => a.depth - b.depth)
    for (const link of projectedLinks) {
      const active = fresh && !warmingUp && flowRate(link) > 0
      const emphasized = chosen && (chosen === link.id || chosen === link.from || chosen === link.to)
      const dim = chosen && !emphasized
      const color = link.local ? colors.local : colors.accent
      const weight = active ? 0.6 + Math.sqrt(flowRate(link) / maximum) * 3.5 : 0.55
      const first = link.points[0], last = link.points.at(-1)
      const gradient = ctx.createLinearGradient(first.x, first.y, last.x, last.y)
      for (const [stop, index] of [[0, 0], [0.5, 24], [1, 48]]) {
        const depth = (link.points[index].z + 1) / 2
        const alpha = dim ? 0.018 : emphasized ? 0.9 : active ? 0.12 + depth ** 2 * 0.72 : 0.045
        gradient.addColorStop(stop, rgba(active || emphasized ? color : colors.thread, alpha))
      }
      stroke(link.points, link.from === link.to ? rgba(color, active ? 0.28 : 0.05) : gradient, 1, weight)
      wires.push(link)
      if (!active || reducedMotion || dim) continue
      for (const [direction, speed] of [[1, link.sent], [-1, link.received]]) {
        if (speed <= 0) continue
        const phase = flowPhase(time, speed, link.id, direction < 0)
        const fade = Math.min(1, phase * 12, (1 - phase) * 12)
        const tail = Array.from({ length: 11 }, (_, i) => project(sphereCurve(link.a.position, link.b.position, clamp(phase - direction * (10 - i) * 0.008, 0, 1), link.local)))
        const glow = ctx.createLinearGradient(tail[0].x, tail[0].y, tail.at(-1).x, tail.at(-1).y)
        glow.addColorStop(0, rgba(color, 0)); glow.addColorStop(1, rgba(color, fade * (0.5 + tail.at(-1).z * 0.2)))
        stroke(tail, glow, 1, 2)
        const point = project(sphereCurve(link.a.position, link.b.position, phase, link.local))
        ctx.globalAlpha = fade * (0.5 + (point.z + 1) * 0.25)
        ctx.beginPath(); ctx.arc(point.x, point.y, 2.2 * point.scale, 0, Math.PI * 2)
        ctx.fillStyle = color; ctx.fill()
        ctx.beginPath(); ctx.arc(point.x - 0.3, point.y - 0.3, 0.8 * point.scale, 0, Math.PI * 2)
        ctx.fillStyle = '#ffffff'; ctx.fill()
      }
    }

    hits = nodes.map(node => ({ ...node, screen: project(node.position) })).sort((a, b) => a.screen.z - b.screen.z)
    for (const node of hits) {
      const p = node.screen, dim = chosen && !related.has(node.id)
      const active = fresh && !warmingUp && (loads.get(node.id) ?? 0) > 0
      const depth = (p.z + 1) / 2
      const alpha = dim ? 0.07 : 0.12 + depth ** 1.8 * 0.88
      const size = (active ? 4.8 : 3.3) * p.scale
      const color = localColor(node)
      if (active && p.z > 0) {
        ctx.globalAlpha = 0.07 * depth
        ctx.beginPath(); ctx.arc(p.x, p.y, size + 5, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill()
      }
      ctx.globalAlpha = alpha
      const bead = ctx.createRadialGradient(p.x - size * 0.35, p.y - size * 0.4, 0, p.x, p.y, size)
      bead.addColorStop(0, colors.card); bead.addColorStop(0.4, color); bead.addColorStop(1, color)
      ctx.beginPath(); ctx.arc(p.x, p.y, size, 0, Math.PI * 2)
      ctx.fillStyle = node.members ? colors.card : bead; ctx.fill()
      ctx.strokeStyle = color; ctx.lineWidth = 0.7; ctx.setLineDash(node.members ? [2, 2] : []); ctx.stroke(); ctx.setLineDash([])
      if (node.id === chosen) {
        ctx.beginPath(); ctx.arc(p.x, p.y, size + 5, 0, Math.PI * 2)
        ctx.strokeStyle = color; ctx.globalAlpha = 0.5; ctx.stroke()
      }
    }

    const labelled = [...hits].filter(n => n.id === chosen || n.screen.z > 0.05 && (!chosen || related.has(n.id)))
      .sort((a, b) => Number(b.id === chosen) - Number(a.id === chosen) || (loads.get(b.id) ?? 0) - (loads.get(a.id) ?? 0) || b.screen.z - a.screen.z)
    const labelBoxes = []
    ctx.font = '12px -apple-system, system-ui, sans-serif'
    for (const node of labelled.slice(0, chosen ? 14 : 9)) {
      const p = node.screen, right = p.x >= cx
      const cap = width < 740 ? 18 : 25, name = shortName(node, cap)
      const textWidth = ctx.measureText(name).width
      const edge = right ? Math.min(width - textWidth - 14, cx + r + 22) : Math.max(textWidth + 14, cx - r - 22)
      let y = clamp(p.y, cy - r + 15, cy + r - 15)
      for (let attempt = 0; attempt < 12 && labelBoxes.some(b => b.right === right && Math.abs(b.y - y) < 23); attempt++) y += y < cy ? -23 : 23
      y = clamp(y, 70, height - 62)
      if (labelBoxes.some(b => b.right === right && Math.abs(b.y - y) < 19) && node.id !== chosen) continue
      labelBoxes.push({ right, y })
      const lineEnd = right ? edge - 6 : edge + 6
      stroke([p, { x: right ? Math.max(p.x + 8, edge - 14) : Math.min(p.x - 8, edge + 14), y }, { x: lineEnd, y }], colors.thread, 0.55, 0.65)
      ctx.globalAlpha = node.id === chosen ? 1 : 0.9
      ctx.fillStyle = node.kind === 'remote' ? colors.muted : colors.ink
      ctx.textAlign = right ? 'left' : 'right'; ctx.fillText(name, edge, y + 3)
    }
    const localAnchor = project([-0.82, 0, 0]), remoteAnchor = project([0.65, 0, 0])
    ctx.globalAlpha = 0.8; ctx.fillStyle = colors.muted; ctx.font = '500 11px -apple-system, system-ui, sans-serif'; ctx.textAlign = 'center'
    ctx.fillText('On this Mac', localAnchor.x, cy - r - 25)
    ctx.fillText('External', remoteAnchor.x, cy - r - (Math.abs(localAnchor.x - remoteAnchor.x) < 90 ? 42 : 25))
    ctx.textAlign = 'start'; ctx.globalAlpha = 1
  }

  return {
    update(graph) {
      if (graphAt !== graph) { nodes = sphereNodes(graph.nodes, nodes); links = graph.links; graphAt = graph }
    },
    highlight(id) { chosen = id },
    resize(w, h) { width = w; height = h; radius = Math.max(95, Math.min(w / 2 - 155, h / 2 - 85)); cx = w / 2; cy = h / 2 + 8 },
    setOrbit(value) { orbit = value }, reset, draw,
    destroy() { disposed = true; for (const args of listeners) canvas.removeEventListener(...args); ctx.clearRect(0, 0, canvas.width, canvas.height) },
  }
}
