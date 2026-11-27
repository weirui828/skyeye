import { d3, bytes } from './util.js'
import { mountGlobe } from './globe.js'
import { flowPhase, shortName } from './flow-style.js'

const rate = n => `${bytes(Math.max(0, n))}/s`
const total = link => link.sent + link.received
const color = node => node.key?.startsWith('local:') ? 'var(--local)' : node.kind === 'remote' ? 'var(--accent)' : 'var(--node-ink)'

export function projectActivity(sample, { query = '', focus = null, previous = [] } = {}) {
  const lookup = new Map((sample.nodes ?? []).map(n => [n.id, n]))
  const needle = query.trim().toLocaleLowerCase()
  const links = (sample.links ?? []).filter(l => {
    if (focus && l.from !== focus && l.to !== focus) return false
    return !needle || [lookup.get(l.from)?.name, lookup.get(l.to)?.name, ...l.hosts, ...l.ports].some(v => String(v ?? '').toLocaleLowerCase().includes(needle))
  })
  const weights = new Map()
  for (const l of links) for (const id of [l.from, l.to]) weights.set(id, (weights.get(id) ?? 0) + total(l) + l.connections)
  const remembered = new Map((query || focus ? [] : previous).map(n => [n.id, n]))
  const active = [...lookup.values()].filter(n => weights.has(n.id)).map(node => {
    const last = remembered.get(node.id)
    const elapsed = Math.max(0, (sample.at ?? 0) - (last?.scoreAt ?? 0))
    const score = Math.max(weights.get(node.id), (last?.score ?? 0) * Math.exp(-elapsed / 6500))
    return { ...node, score, scoreAt: sample.at ?? 0 }
  })
  const remap = new Map()
  const nodes = []
  for (const external of [false, true]) {
    const candidates = active.filter(n => (n.kind === 'remote') === external)
      .sort((a, b) => (b.id === focus) - (a.id === focus) || b.score * (remembered.has(b.id) ? 1.12 : 1) - a.score * (remembered.has(a.id) ? 1.12 : 1) || a.name.localeCompare(b.name))
    const cap = external ? 9 : 12
    nodes.push(...candidates.slice(0, cap))
    for (const n of candidates.slice(0, cap)) remap.set(n.id, n.id)
    const rest = candidates.slice(cap)
    if (rest.length) {
      const id = external ? 'group:remote' : 'group:program'
      nodes.push({ id, name: `Other ${external ? 'destinations' : 'programs'} · ${rest.length}`, kind: external ? 'remote' : 'program', pids: [], members: rest })
      for (const n of rest) remap.set(n.id, id)
    }
  }
  const grouped = new Map()
  for (const l of links) {
    const from = remap.get(l.from), to = remap.get(l.to)
    const id = JSON.stringify([from, to, l.local])
    const item = grouped.get(id) ?? { ...l, id, from, to, sent: 0, received: 0, connections: 0, ports: [], hosts: [], protocols: [] }
    item.sent += l.sent; item.received += l.received; item.connections += l.connections
    for (const key of ['ports', 'hosts', 'protocols']) item[key] = [...new Set([...item[key], ...l[key]])]
    grouped.set(id, item)
  }
  return { nodes, links: [...grouped.values()], connections: links.reduce((sum, l) => sum + l.connections, 0) }
}

export function layoutActivity(graph, width, height) {
  const external = graph.links.filter(l => !l.local)
  const internal = graph.links.filter(l => l.local)
  const externalIDs = new Set(external.flatMap(l => [l.from, l.to]))
  const localIDs = new Set(internal.flatMap(l => [l.from, l.to]))
  const split = external.length > 0 && internal.length > 0
  const nodes = [], arcs = [], captions = [], circles = [], summaries = []
  const loads = new Map()
  for (const link of graph.links) for (const id of [link.from, link.to]) loads.set(id, (loads.get(id) ?? 0) + total(link))
  if (external.length) {
    const r = Math.min(height * 0.35, split ? width * 0.25 : width / 2 - 125)
    const cx = split ? width * 0.36 : width / 2
    const cy = Math.min(height * 0.58, height - r - 50)
    for (const remote of [false, true]) {
      const side = graph.nodes.filter(n => externalIDs.has(n.id) && (n.kind === 'remote') === remote).sort((a, b) => a.name.localeCompare(b.name))
      side.forEach((n, i) => {
        const y = -r + (i + 0.5) * 2 * r / side.length
        const x = Math.sqrt(Math.max(0, r * r - y * y)) * (remote ? 1 : -1)
        nodes.push({ ...n, key: `external:${n.id}`, x: cx + x, y: cy + y, cx, cy, right: remote, compact: false, load: loads.get(n.id) ?? 0 })
      })
      arcs.push(`M${cx},${cy - r} A${r},${r} 0 0,${remote ? 1 : 0} ${cx},${cy + r}`)
      captions.push({ text: remote ? 'External' : 'On this Mac', x: cx + (remote ? 1 : -1) * r * 0.65, y: cy - r - 22 })
    }
  }
  if (internal.length) {
    const r = split ? Math.min(76, width * 0.095, height * 0.15) : Math.min(width / 2 - 130, height / 2 - 70)
    const cx = split ? width - 155 : width / 2
    const cy = split ? r + 55 : height / 2 - 5
    const ring = graph.nodes.filter(n => localIDs.has(n.id)).sort((a, b) => a.name.localeCompare(b.name))
    ring.forEach((n, i) => {
      const angle = (i + 0.5) / ring.length * Math.PI * 2 - Math.PI / 2
      nodes.push({ ...n, key: `local:${n.id}`, x: cx + Math.cos(angle) * r, y: cy + Math.sin(angle) * r,
        cx, cy, right: Math.cos(angle) >= 0, compact: split, quiet: split && ring.length > 8, load: loads.get(n.id) ?? 0 })
    })
    circles.push({ cx, cy, r })
    captions.push({ text: 'Inside this Mac', x: cx, y: cy - r - 22 })
    summaries.push({ text: `${internal.reduce((sum, l) => sum + l.connections, 0)} connections`, x: cx, y: cy + 4 })
  }
  return { nodes, arcs, circles, captions, summaries }
}

export function mountMonitoring(root) {
  root.replaceChildren()
  root.classList.add('monitoring-board')
  const panel = document.createElement('div')
  panel.className = 'monitoring-root'
  panel.dataset.palette = 'orange'
  panel.innerHTML = `
    <div class="monitor-metrics">
      <div><span class="metric-label">Download</span><strong data-metric="received">—</strong><svg class="metric-spark" data-spark="received" viewBox="0 0 72 18" aria-hidden="true"><path></path></svg></div>
      <div><span class="metric-label">Upload</span><strong data-metric="sent">—</strong><svg class="metric-spark" data-spark="sent" viewBox="0 0 72 18" aria-hidden="true"><path></path></svg></div>
      <div><span class="metric-label">Inside this Mac</span><strong data-metric="internalRate">—</strong><svg class="metric-spark" data-spark="internalRate" viewBox="0 0 72 18" aria-hidden="true"><path></path></svg></div>
      <div class="metric-count"><span class="metric-label">Connections</span><strong data-metric="connections">—</strong></div>
    </div>
    <div class="monitor-controls">
      <div class="monitor-navigation"><div class="monitor-view" role="group" aria-label="View">
        <button data-view="2d" aria-pressed="true">2D</button><button data-view="3d" aria-pressed="false">3D</button>
      </div></div>
      <div class="monitor-tools">
        <input class="monitor-search" type="search" placeholder="Find a program, host or port" aria-label="Find a program, host or port">
      </div>
    </div>
    <div class="monitor-body">
      <div class="monitor-canvas"><div class="stage-heading"><span>Network</span><small></small></div><svg class="monitor-map" role="img" aria-label="Live network connections"></svg>
        <canvas class="monitor-globe" role="img" aria-label="3D network sphere" tabindex="0" hidden></canvas>
        <div class="globe-controls" hidden><button data-orbit aria-pressed="true">Rotate</button><button data-reset>Reset</button></div>
        <p class="monitor-empty">Reading network counters…</p>
        <div class="monitor-legend"><span class="legend-local">Inside this Mac</span><span class="legend-remote">External</span><span class="monitor-freshness">Waiting for samples</span></div>
      </div>
      <aside class="monitor-detail"><div class="detail-heading"></div><div class="detail-content"></div></aside>
    </div>`
  root.append(panel)
  const map = d3.select(panel.querySelector('.monitor-map'))
  const gradient = map.append('defs').append('linearGradient').attr('id', 'network-current')
  gradient.append('stop').attr('offset', '0%').attr('stop-color', 'var(--node-ink)').attr('stop-opacity', 0.45)
  gradient.append('stop').attr('offset', '55%').attr('stop-color', 'var(--accent)').attr('stop-opacity', 0.9)
  gradient.append('stop').attr('offset', '100%').attr('stop-color', 'var(--accent)')
  const scene = map.append('g')
  const guides = scene.append('g').attr('class', 'monitor-guides')
  const paths = scene.append('g')
  const particles = scene.append('g').attr('class', 'monitor-particles').attr('aria-hidden', 'true')
  const peers = scene.append('g')
  const center = scene.append('g').attr('class', 'monitor-center')
  let sample = null, projected = null, selected = null, hovered = null
  let query = '', focus = null, mode = '2d'
  let width = 800, height = 600, destroyed = false, animation = 0, lastTick = 0
  let lastFreshness = null
  const positions = new Map()
  let trend = [], showQuiet = false
  const chosen = () => selected ?? hovered
  const fresh = () => sample && sample.active !== false && Date.now() - sample.at < 5000
  const visibleRate = value => fresh() && !sample.warmingUp ? value : 0
  const heading = panel.querySelector('.detail-heading')
  const content = panel.querySelector('.detail-content')
  const globeCanvas = panel.querySelector('.monitor-globe')
  const orbitButton = panel.querySelector('[data-orbit]')
  const globe = mountGlobe(globeCanvas, {
    onSelect(id) { selected = selected === id ? null : id; if (id === null) focus = null; paint() },
    onHover(id) { if (hovered !== id) { hovered = id; highlight() } },
  })

  function button(text, action, className = '') {
    const el = document.createElement('button')
    el.textContent = text; el.className = className; el.addEventListener('click', action)
    return el
  }

  function details() {
    if (!sample || !projected) return
    heading.replaceChildren()
    content.replaceChildren()
    const node = projected.nodes.find(n => n.id === selected)
    const link = projected.links.find(l => l.id === selected)
    const names = new Map(projected.nodes.map(n => [n.id, n.name]))
    if (selected || focus) heading.append(button('← All activity', () => { selected = null; focus = null; paint() }, 'detail-back'))
    const title = document.createElement('h3')
    title.textContent = node?.name ?? (link ? `${names.get(link.from)} ↔ ${names.get(link.to)}` : 'Live traffic')
    if (!node && !link) {
      const count = document.createElement('span')
      count.className = 'activity-count'
      count.textContent = projected.links.length
      title.append(count)
    }
    heading.append(title)
    if (node?.members) {
      for (const member of node.members) content.append(button(member.name, () => { selected = member.id; focus = member.id; paint() }, 'activity-row'))
      return
    }
    if (node) {
      const p = document.createElement('p')
      p.className = 'detail-meta'
      p.textContent = node.pids?.length ? `PID ${node.pids.join(', ')}` : node.kind === 'remote' ? 'External destination' : 'Local endpoint · process unavailable'
      heading.append(p)
      if (focus !== node.id) heading.append(button('Focus', () => { focus = node.id; paint() }, 'detail-focus'))
    }
    if (link) {
      const info = document.createElement('p')
      info.className = 'detail-meta'
      info.textContent = `${link.local ? 'Inside this Mac' : 'External'} · ${link.connections} connections · ${link.protocols.join(', ')}`
      content.append(info)
      for (const [label, value] of [[`${names.get(link.from)} → ${names.get(link.to)}`, link.sent], [`${names.get(link.to)} → ${names.get(link.from)}`, link.received]]) {
        const p = document.createElement('p'); p.className = 'detail-direction'
        p.textContent = `${label}  ${fresh() && !sample.warmingUp ? rate(value) : '—'}`; content.append(p)
      }
      const ports = document.createElement('p'); ports.className = 'detail-meta'
      ports.textContent = `Ports ${link.ports.join(', ')}`; content.append(ports)
      for (const host of link.hosts.slice(0, 80)) {
        const p = document.createElement('p'); p.className = 'detail-host'; p.textContent = host; content.append(p)
      }
      if (link.hosts.length > 80) { const p = document.createElement('p'); p.textContent = `+${link.hosts.length - 80} addresses`; content.append(p) }
      return
    }
    const sorted = projected.links.filter(l => !node || l.from === node.id || l.to === node.id)
      .sort((a, b) => total(b) - total(a) || b.connections - a.connections)
    const shown = node || showQuiet ? sorted : sorted.filter(l => total(l) > 0).slice(0, 8)
    const maximum = Math.max(1, ...shown.map(total))
    for (const l of shown) {
      const row = button('', () => { selected = l.id; details(); highlight() }, 'activity-row')
      const words = document.createElement('span')
      words.className = 'row-names'
      const name = document.createElement('b'), target = document.createElement('span')
      name.textContent = node ? names.get(l.from === node.id ? l.to : l.from) : names.get(l.from)
      target.textContent = node ? `${l.connections} connections` : names.get(l.to)
      words.append(name, target)
      const number = document.createElement('small')
      number.textContent = fresh() && !sample.warmingUp ? rate(total(l)) : '—'
      const meter = document.createElement('i')
      meter.className = `row-meter${l.local ? ' local' : ''}`
      meter.style.width = `${100 * Math.sqrt(visibleRate(total(l)) / maximum)}%`
      row.append(words, number, meter); content.append(row)
    }
    if (!node && sorted.length > shown.length) content.append(button(`${sorted.length - shown.length} more connections`, () => { showQuiet = true; details() }, 'quiet-toggle'))
    else if (!node && showQuiet) content.append(button('Show less', () => { showQuiet = false; details() }, 'quiet-toggle'))
    if (!shown.length) {
      const p = document.createElement('p'); p.className = 'detail-meta'
      p.textContent = sorted.length ? 'Quiet right now' : 'No matching connections'; content.prepend(p)
    }
  }

  function highlight() {
    const id = chosen()
    globe.highlight(id)
    const link = projected?.links.find(l => l.id === id)
    const related = new Set(link ? [link.from, link.to] : id ? [id] : [])
    for (const l of projected?.links ?? []) if (l.from === id || l.to === id) { related.add(l.from); related.add(l.to) }
    paths.selectAll('.monitor-link').classed('dim', l => Boolean(id && l.id !== id && l.from !== id && l.to !== id))
      .classed('emphasized', l => Boolean(id && (l.id === id || l.from === id || l.to === id)))
    particles.selectAll('g').classed('dim', l => Boolean(id && l.id !== id && l.from !== id && l.to !== id))
    peers.selectAll('g').classed('dim', n => Boolean(id && !related.has(n.id)))
      .classed('picked', n => n.id === id)
  }

  function geometry(link) {
    const area = link.local ? 'local' : 'external'
    const a = positions.get(`${area}:${link.from}`), b = positions.get(`${area}:${link.to}`)
    if (!a || !b) return ''
    if (link.from === link.to) {
      const loop = a.compact ? 22 : 45
      return `M${a.x},${a.y} C${a.x + loop},${a.y - loop} ${a.x - loop},${a.y - loop} ${a.x},${a.y}`
    }
    if (!link.local) {
      const bend = (b.x - a.x) * 0.44
      return `M${a.x},${a.y} C${a.x + bend},${a.y} ${b.x - bend},${b.y} ${b.x},${b.y}`
    }
    return `M${a.x},${a.y} C${a.cx + (a.x - a.cx) * 0.2},${a.cy + (a.y - a.cy) * 0.2} ${b.cx + (b.x - b.cx) * 0.2},${b.cy + (b.y - b.cy) * 0.2} ${b.x},${b.y}`
  }

  function paint() {
    if (!sample || destroyed) return
    projected = projectActivity(sample, { query, focus, previous: projected?.nodes ?? [] })
    if (selected && !projected.nodes.some(n => n.id === selected) && !projected.links.some(l => l.id === selected)) selected = null
    map.attr('hidden', mode === '3d' ? '' : null)
    globeCanvas.hidden = mode !== '3d'
    panel.querySelector('.globe-controls').hidden = mode !== '3d'
    if (mode === '3d') globe.update(projected)
    else paintFlat()
    paintReadouts()
  }

  function paintFlat() {
    const layout = layoutActivity(projected, width, height)
    guides.selectAll('path').data(layout.arcs).join('path').attr('d', d => d)
    guides.selectAll('circle').data(layout.circles).join('circle').attr('cx', d => d.cx).attr('cy', d => d.cy).attr('r', d => d.r)
    guides.selectAll('text').data(layout.captions).join('text').attr('x', d => d.x).attr('y', d => d.y)
      .attr('text-anchor', 'middle').text(d => d.text)
    center.selectAll('text').data(layout.summaries).join('text').attr('class', 'center-count')
      .attr('x', d => d.x).attr('y', d => d.y).text(d => d.text)
    positions.clear()
    for (const n of layout.nodes) positions.set(n.key, n)
    const maxRate = Math.max(1, ...projected.links.map(total))
    const dominant = new Set([...projected.links].filter(l => total(l) > 0).sort((a, b) => total(b) - total(a)).slice(0, 4).map(l => l.id))
    const line = paths.selectAll('path').data(projected.links, l => l.id)
    line.exit().filter(function() { return !this.classList.contains('departing') }).classed('departing', true)
      .interrupt().transition().duration(650).style('opacity', 0).remove()
    const enter = line.enter().append('path').attr('class', 'monitor-link').attr('d', geometry).style('opacity', 0)
      .on('mouseenter', (_, l) => { hovered = l.id; highlight() })
      .on('mouseleave', () => { hovered = null; highlight() })
      .on('click', (_, l) => { selected = selected === l.id ? null : l.id; details(); highlight() })
    enter.append('title')
    const merged = enter.merge(line).classed('departing', false).classed('local', l => l.local)
      .classed('carrying', l => visibleRate(total(l)) > 0).classed('dominant', l => dominant.has(l.id) && visibleRate(total(l)) > 0)
    merged.select('title').text(l => `${l.connections} connections · ${l.protocols.join('/')} · ${fresh() ? rate(total(l)) : '—'}`)
    merged.interrupt().transition().duration(650).style('opacity', 1).attr('d', geometry)
      .attr('stroke-width', l => 0.6 + Math.sqrt(visibleRate(total(l)) / maxRate) * 4.5)
    const dots = peers.selectAll('g').data(layout.nodes, n => n.key)
    dots.exit().filter(function() { return !this.classList.contains('departing') }).classed('departing', true)
      .interrupt().transition().duration(500).style('opacity', 0).remove()
    const added = dots.enter().append('g').attr('class', 'monitor-peer').style('opacity', 0)
      .attr('transform', n => `translate(${n.x},${n.y})`).attr('tabindex', 0).attr('role', 'button')
      .on('mouseenter', (_, n) => { hovered = n.id; highlight() })
      .on('mouseleave', () => { hovered = null; highlight() })
      .on('click', (_, n) => { selected = selected === n.id ? null : n.id; details(); highlight() })
      .on('keydown', (e, n) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selected = n.id; details(); highlight() } })
    added.append('circle').attr('class', 'node-halo').attr('r', 13)
    added.append('circle').attr('class', 'node-core').attr('r', 5.5)
    added.append('text').attr('class', 'peer-name')
    added.append('text').attr('class', 'peer-rate')
    added.append('title')
    const allDots = added.merge(dots).classed('departing', false).classed('compact', n => n.compact)
      .classed('quiet-labels', n => n.quiet).classed('busy', n => visibleRate(n.load) > 0).classed('remote', n => n.kind === 'remote')
      .classed('cluster', n => Boolean(n.members)).classed('local', n => n.key.startsWith('local:')).attr('aria-label', n => `${n.name} · ${n.compact ? 'inside this Mac' : n.kind === 'remote' ? 'external' : 'on this Mac'}`)
    allDots.interrupt().transition().duration(650).style('opacity', 1)
      .attr('transform', n => { return `translate(${n.x},${n.y})` })
    allDots.select('.node-core').attr('fill', color).attr('r', n => n.compact ? 3 : 4.6)
    allDots.select('.node-halo').attr('fill', color).attr('r', n => n.compact ? 9 : 11)
    allDots.select('title').text(n => n.name)
    allDots.select('.peer-name').attr('x', n => n.right ? (n.compact ? 9 : 12) : (n.compact ? -9 : -12))
      .attr('dy', n => !n.compact && visibleRate(n.load) > 0 ? '-0.2em' : '0.35em').attr('text-anchor', n => n.right ? 'start' : 'end')
      .text(n => shortName(n, n.compact ? 14 : width < 740 ? 20 : 27))
    allDots.select('.peer-rate').attr('x', n => n.right ? 13 : -13).attr('y', 13)
      .attr('text-anchor', n => n.right ? 'start' : 'end').text(n => !n.compact && visibleRate(n.load) > 0 ? rate(n.load) : '')
    // One group per connection; particles use the same interpolated path as the visible line.
    const moving = particles.selectAll('g').data(projected.links, l => l.id).join('g')
    moving.each(function(l) {
      const group = d3.select(this).classed('local', l.local)
      group.selectAll('path').data([0, 1]).join('path').attr('class', 'flow-streak')
      group.selectAll('circle').data([0, 1]).join('circle').attr('r', 2.1)
    })
  }

  function paintReadouts() {
    panel.querySelector('.stage-heading small').textContent = `${sample.nodes.filter(n => n.pids.length).length} programs · ${projected.connections} connections`
    const empty = panel.querySelector('.monitor-empty')
    empty.hidden = projected.links.length > 0
    empty.textContent = sample.nodes.length ? 'No matching connections' : 'No visible TCP or UDP connections'
    center.style('display', projected.links.length ? null : 'none')
    for (const key of ['sent', 'received', 'internalRate']) {
      const metric = panel.querySelector(`[data-metric="${key}"]`)
      if (fresh() && !sample.warmingUp) {
        const [value, unit] = rate(sample[key]).split(' ')
        const number = document.createElement('span'), suffix = document.createElement('span')
        number.className = 'metric-value'; suffix.className = 'metric-unit'
        number.textContent = value; suffix.textContent = ` ${unit}`
        metric.replaceChildren(number, suffix)
      } else { metric.textContent = '—' }
      const history = trend.filter(point => point.at >= sample.at - 30_000)
      const ceiling = Math.max(1, ...history.map(point => point[key]))
      const path = history.length > 1 ? history.map((point, i) => `${i ? 'L' : 'M'}${(72 * (point.at - sample.at + 30_000) / 30_000).toFixed(1)},${(16 - 13 * point[key] / ceiling).toFixed(1)}`).join(' ') : ''
      panel.querySelector(`[data-spark="${key}"] path`).setAttribute('d', path)
    }
    panel.querySelector('[data-metric="connections"]').textContent = projected.connections
    details(); highlight()
  }

  panel.querySelectorAll('[data-view]').forEach(b => b.addEventListener('click', () => {
    mode = b.dataset.view; hovered = null
    panel.dataset.view = mode
    panel.querySelectorAll('[data-view]').forEach(button => button.setAttribute('aria-pressed', String(button === b)))
    paint()
  }))
  orbitButton.addEventListener('click', () => {
    const active = orbitButton.getAttribute('aria-pressed') !== 'true'
    orbitButton.setAttribute('aria-pressed', String(active)); globe.setOrbit(active)
  })
  panel.querySelector('[data-reset]').addEventListener('click', () => globe.reset())
  panel.querySelector('input').addEventListener('input', e => { query = e.target.value; focus = null; selected = null; paint() })
  map.on('click', e => { if (e.target === map.node()) { selected = null; focus = null; paint() } })
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)')
  function tick(time) {
    if (destroyed) return
    animation = requestAnimationFrame(tick)
    if (document.hidden || time - lastTick < 32) return
    lastTick = time
    const isFresh = Boolean(fresh())
    if (lastFreshness !== isFresh) {
      lastFreshness = isFresh
      panel.querySelector('.monitor-freshness').textContent = isFresh ? '1 second samples' : sample?.active === false ? 'Paused' : sample ? 'No fresh sample' : 'Waiting for samples'
      if (sample) paint()
    }
    if (mode === '3d') {
      globe.draw(time, { fresh: isFresh, warmingUp: sample?.warmingUp, reducedMotion: reducedMotion.matches })
      return
    }
    const pathByID = new Map(paths.selectAll('path').nodes().map(path => [d3.select(path).datum().id, path]))
    particles.selectAll('g').each(function(l) {
      if (!isFresh || reducedMotion.matches || visibleRate(total(l)) <= 0) {
        d3.select(this).selectAll('circle, path').attr('visibility', 'hidden')
        return
      }
      const path = pathByID.get(l.id)
      const length = path?.getTotalLength() ?? 0
      d3.select(this).selectAll('circle').each(function(index) {
        const forward = index === 0
        const speed = visibleRate(forward ? l.sent : l.received)
        const dot = d3.select(this)
        const streak = d3.select(this.parentNode).selectAll('path').filter(d => d === index)
        if (!length || speed <= 0 || reducedMotion.matches || !isFresh) { dot.attr('visibility', 'hidden'); streak.attr('visibility', 'hidden'); return }
        dot.attr('visibility', 'visible')
        const phase = flowPhase(time, speed, l.id, !forward)
        const point = path.getPointAtLength(phase * length)
        const opacity = Math.min(1, phase * 12, (1 - phase) * 12)
        dot.attr('cx', point.x).attr('cy', point.y).attr('opacity', opacity)
        const tail = Array.from({ length: 7 }, (_, i) => {
          const t = Math.max(0, Math.min(1, phase - (forward ? 1 : -1) * (1 - i / 6) * 0.085))
          const p = path.getPointAtLength(t * length)
          return `${i ? 'L' : 'M'}${p.x.toFixed(1)},${p.y.toFixed(1)}`
        }).join(' ')
        streak.attr('visibility', 'visible').attr('d', tail).attr('opacity', opacity * 0.55)
      })
    })
  }
  animation = requestAnimationFrame(tick)
  const observer = new ResizeObserver(entries => {
    const rect = entries[0].contentRect
    width = Math.max(400, rect.width); height = Math.max(400, rect.height)
    map.attr('viewBox', `0 0 ${width} ${height}`)
    globe.resize(width, height)
    paint()
  })
  observer.observe(panel.querySelector('.monitor-canvas'))
  return {
    update(value) {
      if (!value.nodes || !value.links) return
      if (value.active !== false && !value.warmingUp && value.at > (trend.at(-1)?.at ?? 0)) {
        if (trend.length && value.at - trend.at(-1).at > 5000) trend = []
        trend.push({ at: value.at, sent: value.sent, received: value.received, internalRate: value.internalRate })
        trend = trend.filter(point => point.at >= value.at - 30_000).slice(-60)
      }
      sample = value; lastFreshness = null; paint()
    },
    destroy() { destroyed = true; globe.destroy(); cancelAnimationFrame(animation); observer.disconnect(); paths.selectAll('*').interrupt(); peers.selectAll('*').interrupt(); root.classList.remove('monitoring-board') },
  }
}
