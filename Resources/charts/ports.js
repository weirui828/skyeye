// The Ports tab: exposure rings, where the ports are, an uptime timeline and a memory treemap.
// Each takes the scan's programs and returns SVG markup; colors live in charts.css.

import { DAY, RADIUS, RISK_LABEL, RISK_ORDER, cut, d3, esc, groupOf, isStale, memory, projectSlots, svg, tip, uptime } from './util.js'

// ---- exposure rings ----------------------------------------------------

export function ringsSvg(programs, now, shown) {
  if (programs.length === 0) return null
  const width = 420
  const height = 250
  const cx = 125
  const cy = height / 2
  const R = { all: 120, lan: 100, loop: 80 }
  const parts = [
    `<circle class="b-all" cx="${cx}" cy="${cy}" r="${R.all}"/>`,
    `<circle class="b-lan" cx="${cx}" cy="${cy}" r="${R.lan}"/>`,
    `<circle class="b-loop" cx="${cx}" cy="${cy}" r="${R.loop}"/>`,
    ...[R.all, R.lan, R.loop].map(r => `<circle class="grid" cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke-width="1"/>`),
    `<text class="muted" x="${cx}" y="${cy - R.all + 13}" text-anchor="middle">every network</text>`,
    `<text class="muted" x="${cx}" y="${cy - R.lan + 13}" text-anchor="middle">local network</text>`,
    `<text class="muted" x="${cx}" y="${cy - R.loop + 13}" text-anchor="middle">this Mac only</text>`,
  ]

  const sorted = [...programs].sort((a, b) => RISK_ORDER.indexOf(a.risk) - RISK_ORDER.indexOf(b.risk))
  const dot = (s, x, y, label) => {
    const r = RADIUS[s.risk]
    parts.push(
      `<circle class="mark r-${s.risk} halo" data-pid="${s.pid}" data-tip="${tip(s, now)}" ` +
        `cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r}" stroke-width="2"/>`,
    )
    if (label) {
      parts.push(
        `<text class="ink" x="${(x + r + 3).toFixed(1)}" y="${(y + 3.5).toFixed(1)}" font-weight="600" pointer-events="none">${s.ports[0]?.port ?? ''}</text>`,
      )
    }
  }

  // this Mac only: a sunflower in the core, the riskiest at its heart
  const core = sorted.filter(s => s.exposure === 'loopback')
  const coreR = R.loop - 20
  core.forEach((s, i) => {
    const rr = coreR * Math.sqrt((i + 0.5) / core.length)
    const a = i * 2.39996
    dot(s, cx + rr * Math.cos(a), cy + 4 + rr * Math.sin(a), s.risk === 'high' || s.risk === 'medium')
  })
  // the two outer bands: spread along the lower arc of each band
  for (const [ring, inner, outer] of [['lan', R.loop, R.lan], ['all', R.lan, R.all]]) {
    const here = sorted.filter(s => s.exposure === ring)
    const mid = (inner + outer) / 2
    const step = Math.min(26, 240 / Math.max(1, here.length))
    here.forEach((s, i) => {
      const a = ((90 + (i - (here.length - 1) / 2) * step) * Math.PI) / 180
      dot(s, cx + mid * Math.cos(a), cy + mid * Math.sin(a), true)
    })
  }

  // legend: risk, its count, and the ring rule
  const lx = 268
  let ly = 34
  parts.push(`<text class="ink" x="${lx}" y="${ly}" font-weight="600" font-size="11">Risk</text>`)
  for (const r of RISK_ORDER) {
    const n = programs.filter(s => s.risk === r).length
    ly += 20
    parts.push(
      `<circle class="r-${r} halo" cx="${lx + 6}" cy="${ly - 3.5}" r="${RADIUS[r]}" stroke-width="2"/>`,
      `<text class="ink" x="${lx + 18}" y="${ly}">${RISK_LABEL[r]}</text>`,
      `<text class="muted" x="${lx + 70}" y="${ly}" text-anchor="end" font-variant-numeric="tabular-nums">${n}</text>`,
    )
  }
  ly += 28
  for (const line of ['Rings: how far a port', 'can be reached from.', 'One dot per program;', 'click one to find it.']) {
    parts.push(`<text class="muted" x="${lx}" y="${ly}">${line}</text>`)
    ly += 13
  }

  const count = e => programs.filter(s => s.exposure === e).length
  const alt =
    `Exposure rings: ${count('loopback')} programs on this Mac only, ${count('lan')} on the local network, ` +
    `${count('all')} on every network. ` +
    RISK_ORDER.map(r => `${programs.filter(s => s.risk === r).length} ${r}`).join(', ') + ' risk.'
  return { svg: svg(width, height, parts.join(''), alt, shown), alt }
}

// ---- where the ports are -----------------------------------------------

// One dot per listening port along the port number, piled up where they crowd.
// The axis is logarithmic within each of the three ranges ports are assigned
// from, so 3000 and 8000 sit apart and the ephemeral ports get room too.
const RANGES = [
  { name: 'system', from: 1, to: 1024 },
  { name: 'registered', from: 1024, to: 49152 },
  { name: 'ephemeral', from: 49152, to: 65535 },
]

export function beeswarmSvg(programs, now, width) {
  const dots = programs
    .flatMap(s => s.ports.map(p => ({ s, port: p.port })))
    .sort((a, b) => a.port - b.port)
  if (dots.length === 0) return null
  const r = 4.5
  const pad = 1.5
  const left = 10
  const right = width - 10
  const span = right - left
  const x = d3.scaleLog()
    .domain([1, 1024, 49152, 65535])
    .range([left, left + span * 0.2, left + span * 0.74, right])
    .clamp(true)

  // Each dot takes the lowest free spot above the axis at its x.
  const placed = []
  for (const d of dots) {
    d.x = x(Math.max(1, d.port))
    const near = placed.filter(p => Math.abs(p.x - d.x) < 2 * r + pad)
    const spots = [0, ...near.map(p => p.y + Math.sqrt((2 * r + pad) ** 2 - (p.x - d.x) ** 2))].sort((a, b) => a - b)
    d.y = spots.find(y => near.every(p => (p.x - d.x) ** 2 + (p.y - y) ** 2 >= (2 * r + pad) ** 2 - 1e-6))
    placed.push(d)
  }
  const top = 16
  const pile = Math.max(...dots.map(d => d.y)) + 2 * r
  const base = top + Math.max(pile, 30) + 4
  const height = base + 20
  const parts = []

  RANGES.forEach((range, i) => {
    const x0 = x(range.from)
    const x1 = x(range.to)
    if (i % 2 === 1) parts.push(`<rect class="wash" x="${x0.toFixed(1)}" y="${top - 4}" width="${(x1 - x0).toFixed(1)}" height="${base - top + 4}"/>`)
    parts.push(`<text class="muted" x="${((x0 + x1) / 2).toFixed(1)}" y="9" text-anchor="middle">${range.name}</text>`)
  })
  parts.push(`<line class="grid" x1="${left}" y1="${base}" x2="${right}" y2="${base}" stroke-width="1"/>`)
  let lastLabel = -Infinity
  for (const tick of [1, 10, 100, 1024, 3000, 8000, 20000, 49152, 65535]) {
    const tx = x(tick)
    parts.push(`<line class="grid" x1="${tx.toFixed(1)}" y1="${base}" x2="${tx.toFixed(1)}" y2="${base + 4}" stroke-width="1"/>`)
    if (tx - lastLabel < 30) continue
    lastLabel = tx
    const anchor = tick === 1 ? 'start' : tick === 65535 ? 'end' : 'middle'
    parts.push(`<text class="muted" x="${tx.toFixed(1)}" y="${base + 15}" text-anchor="${anchor}" font-variant-numeric="tabular-nums">${tick}</text>`)
  }
  // riskiest drawn last, so they sit on top where dots touch
  for (const d of [...dots].sort((a, b) => RISK_ORDER.indexOf(b.s.risk) - RISK_ORDER.indexOf(a.s.risk))) {
    parts.push(
      `<circle class="mark r-${d.s.risk} halo" data-pid="${d.s.pid}" data-tip="${esc(`Port ${d.port}`)}&#10;${tip(d.s, now)}" ` +
        `cx="${d.x.toFixed(1)}" cy="${(base - r - 1 - d.y).toFixed(1)}" r="${r}" stroke-width="1"/>`,
    )
  }

  const inRange = range => dots.filter(d => d.port >= range.from && (d.port < range.to || range.to === 65535)).length
  const alt = `${dots.length} listening ports by number: ` + RANGES.map(range => `${inRange(range)} ${range.name}`).join(', ') + '.'
  return { svg: svg(width, height, parts.join(''), alt), alt }
}

// ---- uptime timeline ---------------------------------------------------

const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export function timelineSvg(servers, now, width) {
  const rows = [...servers].sort((a, b) => a.startedAt - b.startedAt)
  if (rows.length === 0) return null
  const rowH = 18
  const top = 18
  const height = top + rows.length * rowH + 6
  const x0 = 138
  const x1 = width - 48
  const from = now - 7 * DAY
  const x = t => x0 + ((Math.max(t, from) - from) / (now - from)) * (x1 - x0)
  const parts = []

  // a gridline at each local midnight, its weekday above
  const d = new Date(now)
  d.setHours(0, 0, 0, 0)
  for (let t = d.getTime(); t > from; t -= DAY) {
    const gx = x(t)
    parts.push(`<line class="grid" x1="${gx.toFixed(1)}" y1="${top - 4}" x2="${gx.toFixed(1)}" y2="${height - 4}" stroke-width="1"/>`)
    const label = t === d.getTime() ? 'today' : WEEKDAY[new Date(t).getDay()]
    if (gx + 24 < x1 + 30) parts.push(`<text class="muted" x="${(gx + 3).toFixed(1)}" y="${top - 7}">${label}</text>`)
  }
  // the day line: bars that cross it are servers left running
  const dayX = x(now - DAY)
  parts.push(
    `<line class="day" x1="${dayX.toFixed(1)}" y1="${top - 4}" x2="${dayX.toFixed(1)}" y2="${height - 4}" stroke-width="1" stroke-dasharray="3 3"/>`,
  )

  rows.forEach((s, i) => {
    const y = top + i * rowH
    const bx = x(s.startedAt)
    const w = Math.max(3, x1 - bx)
    parts.push(
      `<g class="mark row" data-pid="${s.pid}" data-tip="${tip(s, now)}">` +
        `<rect class="hit" x="0" y="${y}" width="${width}" height="${rowH}" rx="3"/>` +
        `<text class="ink" x="0" y="${y + 12.5}">${esc(cut(`${s.ports[0]?.port ?? ''}  ${s.name}`, 22))}</text>` +
        `<rect class="${isStale(s, now) ? 'stale' : 'fresh'}" x="${bx.toFixed(1)}" y="${y + 4}" width="${w.toFixed(1)}" height="10" rx="3"/>` +
        (s.startedAt < from ? `<text class="ink" x="${x0 - 9}" y="${y + 12.5}">‹</text>` : '') +
        `<text class="muted" x="${x1 + 5}" y="${y + 12.5}" font-variant-numeric="tabular-nums">${uptime(now - s.startedAt)}</text>` +
        `</g>`,
    )
  })

  const stale = rows.filter(s => isStale(s, now)).length
  const alt = `Uptime of ${rows.length} servers over the last 7 days; ${stale} running for more than a day.`
  return { svg: svg(width, height, parts.join(''), alt), alt }
}

// ---- memory treemap ----------------------------------------------------

export function treemapSvg(programs, now, width, height = 200) {
  const live = programs.filter(s => s.rssKb > 0)
  if (live.length === 0) return null
  const groups = new Map()
  for (const s of live) groups.set(groupOf(s), [...(groups.get(groupOf(s)) ?? []), s])
  const slot = projectSlots(programs)

  const data = {
    name: 'memory',
    children: [...groups.entries()].map(([name, list]) => ({
      name,
      children: list.map(s => ({ name: s.name, slot: slot(name), kb: s.rssKb, server: s })),
    })),
  }
  const root = d3.treemap()
    .tile(d3.treemapSquarify)
    .size([width, height])
    .paddingOuter(2)
    .paddingTop(17)
    .paddingInner(2)
    .round(true)(
    d3.hierarchy(data, d => d.children)
      .sum(d => d.kb ?? 0)
      .sort((a, b) => (b.value ?? 0) - (a.value ?? 0)),
  )

  const parts = []
  const kb = live.reduce((t, s) => t + s.rssKb, 0)
  for (const g of root.children ?? []) {
    const w = g.x1 - g.x0
    const total = g.value ?? 0
    parts.push(
      `<rect class="wash" data-tip="${esc(`${g.data.name} — ${memory(total)}`)}" x="${g.x0}" y="${g.y0}" width="${w}" height="${g.y1 - g.y0}" rx="4"/>`,
    )
    if (w > 36) {
      const name = cut(g.data.name, Math.floor((w - 8) / 6.2))
      const showKb = w > name.length * 6.2 + 46
      parts.push(
        `<text class="ink" x="${g.x0 + 4}" y="${g.y0 + 12}" font-weight="600" font-size="11" pointer-events="none">${esc(name)}` +
          (showKb ? `<tspan class="muted" dx="5" font-weight="400" font-size="10">${memory(total)}</tspan>` : '') +
          `</text>`,
      )
    }
    for (const leaf of g.children ?? []) {
      const lw = leaf.x1 - leaf.x0
      const lh = leaf.y1 - leaf.y0
      const fill = leaf.data.slot
      const s = leaf.data.server
      parts.push(
        `<rect class="mark leaf ${fill}" data-pid="${s.pid}" data-tip="${tip(s, now)}" ` +
          `x="${leaf.x0}" y="${leaf.y0}" width="${lw}" height="${lh}" rx="3"/>`,
      )
      if (lw > 44 && lh > 16) {
        const ink = fill === 's3' ? 'on-dark' : 'on'
        parts.push(
          `<text class="${ink}" x="${leaf.x0 + 4}" y="${leaf.y0 + 12}" pointer-events="none">${esc(cut(s.name, Math.floor((lw - 8) / 5.8)))}</text>`,
        )
        if (lh > 30) {
          parts.push(
            `<text class="${ink}" x="${leaf.x0 + 4}" y="${leaf.y0 + 25}" opacity="0.85" pointer-events="none">${memory(s.rssKb)}</text>`,
          )
        }
      }
    }
  }

  const ranked = [...groups.entries()]
    .map(([g, l]) => ({ g, kb: l.reduce((t, s) => t + s.rssKb, 0) }))
    .sort((a, b) => b.kb - a.kb)
  const alt = `Memory by project: ${ranked.map(r => `${r.g} ${memory(r.kb)}`).join(', ')}.`
  return { svg: svg(width, height, parts.join(''), alt), alt, kb }
}
