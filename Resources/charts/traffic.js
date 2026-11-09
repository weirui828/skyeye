// The Traffic tab: who programs talk to (by connections), where the bytes go
// (a sunburst you can zoom into), and bytes per second over the last minutes.

import { bytes, cut, d3, esc, ownerClass, svg } from './util.js'

// ---- outgoing flow -----------------------------------------------------

const MAX_NODES = 10

// Heights proportional to connections, but never below a label's line.
function stack(nodes, height, gap) {
  const minH = 14
  let scale = (height - gap * (nodes.length - 1)) / Math.max(1, nodes.reduce((t, n) => t + n.count, 0))
  for (let round = 0; round < 4; round++) {
    const small = nodes.filter(n => n.count * scale < minH)
    const rest = nodes.filter(n => n.count * scale >= minH).reduce((t, n) => t + n.count, 0)
    if (rest === 0) break
    scale = (height - gap * (nodes.length - 1) - small.length * minH) / rest
  }
  let y = 0
  for (const n of nodes) {
    n.h = Math.max(minH, n.count * scale)
    n.y = y
    n.at = 0
    y += n.h + gap
  }
}

export function flowSvg(talkers, width) {
  if (talkers.length === 0) return null
  const pairs = []
  const left = new Map()
  const right = new Map()

  // past ten a side, the smallest fold into one "Other" node
  const top = counts =>
    new Set(
      [...counts].sort((a, b) => b[1] - a[1]).slice(0, counts.length <= MAX_NODES ? MAX_NODES : MAX_NODES - 1).map(([k]) => k),
    )
  const shown = top(talkers.map(t => [t.name, t.count]))
  const owners = new Map()
  for (const t of talkers) for (const p of t.peers) owners.set(p.owner, (owners.get(p.owner) ?? 0) + p.count)
  const topOwners = top([...owners.entries()])

  for (const t of talkers) {
    const from = shown.has(t.name) ? t.name : 'Other programs'
    const l = left.get(from) ?? { name: from, count: 0, y: 0, h: 0, at: 0 }
    l.count += t.count
    if (t.flags.some(f => f.level === 'alert')) l.alert = true
    left.set(from, l)
    for (const p of t.peers) {
      const to = topOwners.has(p.owner) ? p.owner : 'Other services'
      const r = right.get(to) ?? { name: to, count: 0, y: 0, h: 0, at: 0 }
      r.count += p.count
      right.set(to, r)
      const pair = pairs.find(x => x.from === from && x.to === to)
      if (pair) pair.count += p.count
      else pairs.push({ from, to, count: p.count })
    }
  }

  const last = name => (a, b) => (a.name === name ? 1 : b.name === name ? -1 : b.count - a.count)
  const L = [...left.values()].sort(last('Other programs'))
  const R = [...right.values()].sort(last('Other services'))
  const gap = 5
  const height = Math.max(120, Math.max(L.length, R.length) * 22)
  stack(L, height, gap)
  stack(R, height, gap)
  const y0Top = 16
  const lx = 150
  const rx = width - 150
  const bar = 5
  const parts = [
    `<text class="muted" x="${lx + bar}" y="10" text-anchor="end">programs</text>`,
    `<text class="muted" x="${rx}" y="10">services</text>`,
  ]

  // bands first, ordered so they cross as little as they can
  const li = new Map(L.map((n, i) => [n.name, i]))
  const ri = new Map(R.map((n, i) => [n.name, i]))
  pairs.sort((a, b) => li.get(a.from) - li.get(b.from) || ri.get(a.to) - ri.get(b.to))
  const rightOrder = [...pairs].sort((a, b) => ri.get(a.to) - ri.get(b.to) || li.get(a.from) - li.get(b.from))
  const rightOffset = new Map()
  for (const p of rightOrder) {
    const r = right.get(p.to)
    rightOffset.set(p, r.at)
    r.at += p.count * (r.h / r.count)
  }
  for (const p of pairs) {
    const l = left.get(p.from)
    const r = right.get(p.to)
    const lw = p.count * (l.h / l.count)
    const rw = p.count * (r.h / r.count)
    const y0 = y0Top + l.y + l.at
    const y1 = y0Top + r.y + rightOffset.get(p)
    l.at += lw
    const x0 = lx + bar
    const x1 = rx
    const xm = (x0 + x1) / 2
    parts.push(
      `<path class="band ${ownerClass(p.to)}" ` +
        `data-tip="${esc(`${p.from} → ${p.to}: ${p.count} connection${p.count === 1 ? '' : 's'}`)}" ` +
        `d="M${x0},${y0.toFixed(1)} C${xm},${y0.toFixed(1)} ${xm},${y1.toFixed(1)} ${x1},${y1.toFixed(1)} ` +
        `L${x1},${(y1 + rw).toFixed(1)} C${xm},${(y1 + rw).toFixed(1)} ${xm},${(y0 + lw).toFixed(1)} ${x0},${(y0 + lw).toFixed(1)} Z"/>`,
    )
  }

  for (const n of L) {
    const y = y0Top + n.y
    parts.push(
      `<rect class="${n.alert ? 'alert' : 'node'}" x="${lx}" y="${y.toFixed(1)}" width="${bar}" height="${n.h.toFixed(1)}" rx="2"/>`,
      `<text class="ink" x="${lx - 5}" y="${(y + n.h / 2 + 3.5).toFixed(1)}" text-anchor="end">${n.alert ? '⚑ ' : ''}${esc(cut(n.name, 20))}` +
        `<tspan class="muted" dx="4">${n.count}</tspan></text>`,
    )
  }
  for (const n of R) {
    const y = y0Top + n.y
    parts.push(
      `<rect class="${ownerClass(n.name)}" x="${rx}" y="${y.toFixed(1)}" width="${bar}" height="${n.h.toFixed(1)}" rx="2"/>`,
      `<text class="ink" x="${rx + bar + 5}" y="${(y + n.h / 2 + 3.5).toFixed(1)}">${esc(cut(n.name, 18))}` +
        `<tspan class="muted" dx="4">${n.count}</tspan></text>`,
    )
  }

  const total = L.reduce((t, n) => t + n.count, 0)
  const alt =
    `${total} outgoing connections from ${talkers.length} programs to ${owners.size} services: ` +
    R.map(n => `${n.name} ${n.count}`).join(', ') + '.'
  return { svg: svg(width, y0Top + height + 4, parts.join(''), alt), alt, services: owners.size }
}

// ---- bytes by service --------------------------------------------------

const MAX_OWNERS = 9
const MAX_HOSTS = 6

// service → program → address, sized by bytes in both directions
function trafficTree(traffic) {
  const owners = new Map()
  for (const program of traffic) {
    for (const peer of program.peers) {
      const size = peer.bytesIn + peer.bytesOut
      if (size === 0) continue
      const owner = owners.get(peer.owner) ?? new Map()
      owners.set(peer.owner, owner)
      owner.set(program.name, [...(owner.get(program.name) ?? []), { name: peer.host, size, down: peer.bytesIn, up: peer.bytesOut }])
    }
  }
  const total = hosts => hosts.reduce((t, h) => t + h.size, 0)
  const fold = (hosts, name) => ({
    name, size: total(hosts), down: hosts.reduce((t, h) => t + h.down, 0), up: hosts.reduce((t, h) => t + h.up, 0),
  })
  let children = [...owners.entries()].map(([owner, programs]) => ({
    name: owner,
    owner,
    children: [...programs.entries()].map(([program, hosts]) => {
      hosts.sort((a, b) => b.size - a.size)
      const shown = hosts.length > MAX_HOSTS ? [...hosts.slice(0, MAX_HOSTS - 1), fold(hosts.slice(MAX_HOSTS - 1), 'other addresses')] : hosts
      return { name: program, owner, children: shown.map(h => ({ ...h, owner })) }
    }),
  }))
  const weight = node => (node.children ? node.children.reduce((t, c) => t + weight(c), 0) : node.size)
  children.sort((a, b) => weight(b) - weight(a))
  if (children.length > MAX_OWNERS) {
    const rest = children.slice(MAX_OWNERS - 1)
    children = [
      ...children.slice(0, MAX_OWNERS - 1),
      { name: 'Other services', owner: '', children: rest.flatMap(o => o.children.map(p => ({ ...p, name: `${o.name} · ${p.name}`, owner: '' }))) },
    ]
  }
  return { name: 'All traffic', owner: '', children }
}

const pathOf = node => node.ancestors().reverse().slice(1).map(n => n.data.name)

// Draws into `el`; `view.focus` (a path of names) survives redraws, so a new
// scan does not throw the reader back to the top.
export function mountSunburst(el, traffic, width, view) {
  const data = trafficTree(traffic ?? [])
  if (data.children.length === 0) return null
  const size = Math.min(width, 380)
  const ring = size / 8
  const root = d3.partition().size([2 * Math.PI, 4])(
    d3.hierarchy(data).sum(d => d.size ?? 0).sort((a, b) => b.value - a.value),
  )
  const find = path => {
    let node = root
    for (const name of path ?? []) node = node?.children?.find(c => c.data.name === name)
    return node?.children ? node : root
  }
  const place = (d, focus) => ({
    x0: Math.max(0, Math.min(1, (d.x0 - focus.x0) / (focus.x1 - focus.x0))) * 2 * Math.PI,
    x1: Math.max(0, Math.min(1, (d.x1 - focus.x0) / (focus.x1 - focus.x0))) * 2 * Math.PI,
    y0: Math.max(0, d.y0 - focus.depth),
    y1: Math.max(0, d.y1 - focus.depth),
  })
  let focus = find(view.focus)
  root.each(d => { d.current = place(d, focus) })

  const arc = d3.arc()
    .startAngle(d => d.x0)
    .endAngle(d => d.x1)
    .padAngle(d => Math.min((d.x1 - d.x0) / 2, 0.006))
    .padRadius(ring * 1.5)
    .innerRadius(d => d.y0 * ring)
    .outerRadius(d => Math.max(d.y0 * ring, d.y1 * ring - 1))
  const visible = d => d.y1 <= 4 && d.y0 >= 1 && d.x1 > d.x0
  // the ring next to the center is the strongest, the outer ones paler
  const shade = d => [0, 0.92, 0.66, 0.44][d.depth - focus.depth] ?? 0.44
  // A wide arc is labelled along its curve, a narrow one along its radius;
  // either way the name is cut to the room there is, or left out.
  const labelFor = g => {
    if (!visible(g)) return null
    const radius = ((g.y0 + g.y1) / 2) * ring
    const length = (g.x1 - g.x0) * radius
    const along = length >= ring
    const chars = Math.floor(((along ? length : ring) - 8) / 5.7)
    if (chars < 4 || length < 11) return null
    const angle = (((g.x0 + g.x1) / 2) * 180) / Math.PI
    const transform = along
      ? `rotate(${angle}) translate(0,${-radius}) rotate(${angle > 90 && angle < 270 ? 180 : 0})`
      : `rotate(${angle - 90}) translate(${radius},0) rotate(${angle < 180 ? 0 : 180})`
    return { transform, chars }
  }
  const describe = d => {
    const path = pathOf(d).join(' → ')
    const leaf = d.data.down !== undefined ? ` (↓${bytes(d.data.down)} ↑${bytes(d.data.up)})` : ''
    return `${path}\n${bytes(d.value)}${leaf} · ${((d.value / root.value) * 100).toFixed(d.value / root.value < 0.1 ? 1 : 0)}% of all traffic`
  }

  const alt =
    `${bytes(root.value)} exchanged with ${root.children.length} services: ` +
    root.children.slice(0, 6).map(c => `${c.data.name} ${bytes(c.value)}`).join(', ') + '.'
  const chart = d3.select(el).html('').append('svg')
    .attr('width', size).attr('height', size)
    .attr('viewBox', `${-size / 2} ${-size / 2} ${size} ${size}`)
    .attr('role', 'img').attr('aria-label', alt)

  const nodes = root.descendants().slice(1)
  const arcs = chart.append('g').selectAll('path').data(nodes).join('path')
    .attr('class', d => `arc ${ownerClass(d.data.owner)}${d.children ? ' zoom' : ''}`)
    .attr('fill-opacity', d => (visible(d.current) ? shade(d) : 0))
    .attr('pointer-events', d => (visible(d.current) ? 'auto' : 'none'))
    .attr('data-tip', describe)
    .attr('d', d => arc(d.current))
  const labels = chart.append('g').attr('pointer-events', 'none').attr('text-anchor', 'middle')
    .selectAll('text').data(nodes).join('text')
    .attr('dy', '0.35em')
  const writeLabels = () => {
    labels.each(function (d) {
      const label = labelFor(d.current)
      // white on the saturated inner ring of the view, ink on the paler rings and on yellow
      const inner = d.depth - focus.depth === 1 && ownerClass(d.data.owner) !== 's3'
      d3.select(this)
        .attr('class', inner ? 'on' : 'ink')
        .attr('fill-opacity', label ? 1 : 0)
        .attr('transform', label?.transform ?? null)
        .text(label ? cut(d.data.name, label.chars) : '')
    })
  }
  writeLabels()

  const center = chart.append('g').attr('class', 'center')
  center.append('circle').attr('r', ring - 2).attr('class', 'hub')
  const title = center.append('text').attr('class', 'ink').attr('text-anchor', 'middle').attr('font-weight', 600).attr('font-size', 11).attr('y', -3)
  const amount = center.append('text').attr('class', 'muted').attr('text-anchor', 'middle').attr('y', 11)
  const hub = () => {
    title.text(cut(focus.data.name, 15))
    amount.text(bytes(focus.value))
    center.classed('zoom', focus !== root)
      .attr('data-tip', focus === root ? 'Click a ring to zoom in' : `${pathOf(focus).join(' → ')}\nClick to zoom out`)
  }
  hub()

  const zoomTo = target => {
    focus = target
    view.focus = pathOf(focus)
    hub()
    root.each(d => { d.target = place(d, focus) })
    // names step aside while the rings move, and are written again for the new view
    labels.attr('fill-opacity', 0)
    const t = chart.transition().duration(450)
    t.end().then(writeLabels, () => {})
    arcs.transition(t)
      .tween('data', d => {
        const i = d3.interpolate(d.current, d.target)
        return time => { d.current = i(time) }
      })
      .filter(function (d) { return +this.getAttribute('fill-opacity') || visible(d.target) })
      .attr('fill-opacity', d => (visible(d.target) ? shade(d) : 0))
      .attr('pointer-events', d => (visible(d.target) ? 'auto' : 'none'))
      .attrTween('d', d => () => arc(d.current))
  }
  arcs.filter(d => d.children).on('click', (event, d) => zoomTo(d))
  center.on('click', () => { if (focus.parent) zoomTo(focus.parent) })
  return { alt, total: root.value, services: root.children.length }
}

// ---- traffic over time -------------------------------------------------

const MAX_RIDGES = 8

export function ridgelineSvg(history, width) {
  const times = history?.times ?? []
  if (times.length < 3) return null
  const sum = s => s.rates.reduce((t, r) => t + r, 0)
  const series = [...history.series].sort((a, b) => sum(b) - sum(a)).slice(0, MAX_RIDGES)
  if (series.length === 0) return null

  const step = 22
  const overlap = 2.6
  const top = step * overlap - step + 6
  const height = top + series.length * step + 22
  const x0 = 132
  const x1 = width - 58
  const now = times[times.length - 1]
  const x = d3.scaleLinear().domain([times[0], now]).range([x0, x1])
  // a square root keeps the quiet programs visible beside the busy one
  const peak = Math.max(1, ...series.flatMap(s => s.rates))
  const y = d3.scaleSqrt().domain([0, peak]).range([0, -step * overlap])
  const area = d3.area().curve(d3.curveMonotoneX).x((_, i) => x(times[i])).y0(0).y1(r => y(r))
  const line = area.lineY1()
  const parts = []

  const span = now - times[0]
  const every = span > 240_000 ? 60_000 : span > 60_000 ? 30_000 : 10_000
  for (let t = now; t >= times[0]; t -= every) {
    const gx = x(t)
    parts.push(`<line class="grid" x1="${gx.toFixed(1)}" y1="6" x2="${gx.toFixed(1)}" y2="${height - 18}" stroke-width="1"/>`)
    const ago = Math.round((now - t) / 1000)
    const label = ago === 0 ? 'now' : ago % 60 === 0 ? `−${ago / 60}m` : `−${ago}s`
    parts.push(`<text class="muted" x="${gx.toFixed(1)}" y="${height - 6}" text-anchor="${ago === 0 ? 'end' : 'middle'}">${label}</text>`)
  }
  series.forEach((s, i) => {
    const base = top + (i + 1) * step
    const latest = s.rates[s.rates.length - 1]
    const most = Math.max(...s.rates)
    parts.push(
      `<g transform="translate(0,${base})" data-tip="${esc(`${s.name}\nnow ${bytes(latest)}/s · peak ${bytes(most)}/s`)}">` +
        `<rect class="hit" x="0" y="${-step}" width="${width}" height="${step}"/>` +
        `<path class="ridge" d="${area(s.rates)}"/>` +
        `<path class="ridge-line" d="${line(s.rates)}" fill="none" stroke-width="1.2"/>` +
        `<line class="grid" x1="${x0}" y1="0" x2="${x1}" y2="0" stroke-width="1"/>` +
        `<text class="ink" x="0" y="-4">${esc(cut(s.name, 21))}</text>` +
        `<text class="muted" x="${x1 + 5}" y="-4" font-variant-numeric="tabular-nums">${bytes(latest)}/s</text>` +
        `</g>`,
    )
  })

  const busiest = series[0]
  const alt =
    `Bytes per second for ${series.length} programs over the last ${Math.round(span / 1000)} seconds; ` +
    `the busiest is ${busiest.name}, peaking at ${bytes(Math.max(...busiest.rates))} per second.`
  return { svg: svg(width, height, parts.join(''), alt), alt, span }
}
