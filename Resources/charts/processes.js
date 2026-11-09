// The Processes tab: who started what (a tree from launchd down to each
// listening program), and which programs on this Mac connect to which.

import { RISK_LABEL, bytes, cut, d3, esc, portsOf, projectSlots, svg } from './util.js'

// ---- who started what --------------------------------------------------

// A branch whose listeners are all quiet app helpers starts folded, so the
// servers you started are what the tree shows first.
function quiet(node) {
  return node.leaves().every(leaf => leaf.data.risk === 'info' || leaf.data.risk == null)
}

// `view.folded` maps a pid to what the reader chose for it; anything they
// have not touched follows the rule above.
export function treeSvg(tree, programs, width, view) {
  if (!tree || tree.length < 2) return null
  const root = d3.stratify().id(d => d.pid).parentId(d => (d.ppid === 0 ? null : d.ppid))(tree)
  root.sort((a, b) => (b.height - a.height) || d3.ascending(a.data.name.toLowerCase(), b.data.name.toLowerCase()))
  const byPid = new Map(programs.map(s => [s.pid, s]))
  const isFolded = node =>
    node.children !== undefined && node.depth > 0 && (view.folded.get(node.data.pid) ?? quiet(node))

  // what is on screen: a folded node keeps its children out of the layout
  const shown = d3.hierarchy(root, node => (isFolded(node) ? null : node.children))
  // A dendrogram: every program at the end of a branch lines up on the right, one per row, so no two
  // names share a line. A process with branches is named to its left, clear of them.
  const rowH = 17
  const left = 58
  const labelRoom = 132
  const depthW = Math.max(36, Math.min(130, (width - left - labelRoom) / Math.max(1, shown.height)))
  d3.cluster().nodeSize([rowH, depthW]).separation(() => 1)(shown)
  let min = Infinity
  let max = -Infinity
  shown.each(n => {
    min = Math.min(min, n.x)
    max = Math.max(max, n.x)
  })
  const height = max - min + rowH + 8
  const yOf = n => n.x - min + rowH / 2 + 4
  const xOf = n => left + n.y
  const link = d3.linkHorizontal().x(n => xOf(n)).y(n => yOf(n))
  const parts = []

  for (const l of shown.links()) parts.push(`<path class="branch" d="${link(l)}" fill="none" stroke-width="1"/>`)
  shown.each(n => {
    const node = n.data
    const d = node.data
    const program = byPid.get(d.pid)
    const folded = isFolded(node)
    const hidden = folded ? node.descendants().length - 1 : 0
    const x = xOf(n)
    const y = yOf(n)
    const branching = n.children !== undefined
    const ports = d.ports.length > 0 ? `  ${d.ports.slice(0, 2).join(', ')}${d.ports.length > 2 ? ` +${d.ports.length - 2}` : ''}` : ''
    // the name is cut to the room it has: the gap to the parent, or the column kept for the leaves
    const room = branching
      ? Math.floor(((n.depth === 0 ? left : depthW) - 12) / 5.6)
      : Math.floor((labelRoom - 14) / 5.9) - ports.length - (folded ? String(hidden).length + 2 : 0)
    const label = cut(d.name, Math.max(4, room)) + ports
    const span = label.length * 5.8 + (folded ? 34 : 16)
    const about = program
      ? `${program.name} · ${portsOf(program)}\n${RISK_LABEL[program.risk]} risk: ${program.reasons.join('; ')}\npid ${d.pid}`
      : `${d.name}\npid ${d.pid}` + (node.children ? `\n${folded ? `${hidden} below — click to open` : 'Click to fold'}` : '')
    const attrs = program ? `data-pid="${d.pid}"` : node.children && node.depth > 0 ? `data-fold="${d.pid}"` : ''
    parts.push(
      `<g class="${program ? 'mark' : node.children && node.depth > 0 ? 'fold' : ''}" ${attrs} data-tip="${esc(about)}">` +
        `<rect class="hit" x="${branching ? x - span + 7 : x - 7}" y="${y - rowH / 2}" width="${span}" height="${rowH}" rx="3"/>` +
        (program
          ? `<circle class="r-${d.risk} halo" cx="${x}" cy="${y}" r="4.5" stroke-width="1"/>`
          : `<circle class="${folded ? 'knot folded' : 'knot'}" cx="${x}" cy="${y}" r="3.5" stroke-width="1.2"/>`) +
        `<text class="${program ? 'ink' : 'muted'}" x="${branching ? x - 8 : x + 8}" y="${y + 3.5}"` +
        `${branching ? ' text-anchor="end"' : ''}${program ? ' font-weight="600"' : ''}>${esc(label)}` +
        (folded ? `<tspan class="muted" dx="5" font-weight="400">+${hidden}</tspan>` : '') +
        `</text></g>`,
    )
  })

  const listeners = tree.filter(d => d.ports.length > 0).length
  const starters = root.children?.length ?? 0
  const alt = `Process tree: ${listeners} listening programs under ${starters} processes started by launchd.`
  return { svg: svg(width, height, parts.join(''), alt), alt, listeners }
}

// ---- connections inside this Mac ---------------------------------------

// Programs sit on a circle, grouped by project; a line joins a program to
// each program whose port it has open. Lines bundle through the groups.
export function bundleSvg(local, programs, width) {
  const nodes = local?.nodes ?? []
  const links = local?.links ?? []
  if (links.length === 0) return null
  const slot = projectSlots(programs)
  const size = Math.min(width, 470)
  const room = 118
  const radius = size / 2 - room

  const groups = d3.group(nodes, n => n.group)
  const root = d3.cluster().size([2 * Math.PI, radius]).separation((a, b) => (a.parent === b.parent ? 1 : 1.6))(
    d3.hierarchy({ id: '', children: [...groups].map(([group, list]) => ({ id: `group ${group}`, children: list })) }),
  )
  const leaf = new Map(root.leaves().map(n => [n.data.id, n]))
  const line = d3.lineRadial().curve(d3.curveBundle.beta(0.8)).radius(n => n.y).angle(n => n.x)
  const most = Math.max(...links.map(l => l.count))
  const parts = [`<g transform="translate(${size / 2},${size / 2})">`]

  const kind = l => (l.declared === true ? 'ok' : l.declared === false ? 'warn' : 'plain')
  const about = l =>
    `${l.from} → ${l.to} on port ${l.port}\n${l.count} connection${l.count === 1 ? '' : 's'} · ${bytes(l.bytes)}` +
    (l.declared === true ? '\nA dependency declared in SkyEye' : l.declared === false ? '\nNot declared as a dependency in SkyEye' : '')
  // the undeclared ones last, so they are drawn on top
  for (const l of [...links].sort((a, b) => (a.declared === false) - (b.declared === false))) {
    const from = leaf.get(l.from)
    const to = leaf.get(l.to)
    if (!from || !to) continue
    parts.push(
      `<path class="wire ${kind(l)}" data-from="${esc(l.from)}" data-to="${esc(l.to)}" data-tip="${esc(about(l))}" ` +
        `d="${line(from.path(to))}" fill="none" stroke-width="${(1 + 2 * (l.count / most)).toFixed(1)}"/>`,
    )
  }
  for (const n of root.leaves()) {
    const deg = (n.x * 180) / Math.PI - 90
    const flip = n.x >= Math.PI
    const out = links.filter(l => l.from === n.data.id).map(l => l.to)
    const into = links.filter(l => l.to === n.data.id).map(l => l.from)
    const tipText =
      n.data.id + (n.data.service ? ` · SkyEye service` : '') +
      (out.length > 0 ? `\nconnects to ${out.join(', ')}` : '') +
      (into.length > 0 ? `\nreached by ${into.join(', ')}` : '') +
      (out.length + into.length === 0 ? '\nno connections to other programs right now' : '')
    parts.push(
      `<g class="peer" data-node="${esc(n.data.id)}" data-tip="${esc(tipText)}" transform="rotate(${deg.toFixed(2)}) translate(${n.y},0)">` +
        `<circle class="${slot(n.data.group)}" r="3.5"/>` +
        `<text class="ink" x="${flip ? -8 : 8}" y="3.5" text-anchor="${flip ? 'end' : 'start'}"${flip ? ' transform="rotate(180)"' : ''}` +
        `${n.data.service ? ' font-weight="600"' : ''}>${esc(cut(n.data.id, 19))}</text></g>`,
    )
  }
  parts.push('</g>')

  // legend, only for the kinds of line that are on the chart
  const kinds = [
    ['ok', 'declared dependency'],
    ['warn', 'not declared in SkyEye'],
    ['plain', 'other programs'],
  ].filter(([k]) => links.some(l => kind(l) === k))
  let lx = 4
  const ly = size + 12
  for (const [k, label] of kinds) {
    parts.push(
      `<line class="wire ${k}" x1="${lx}" y1="${ly - 3.5}" x2="${lx + 16}" y2="${ly - 3.5}" stroke-width="2"/>`,
      `<text class="muted" x="${lx + 21}" y="${ly}">${label}</text>`,
    )
    lx += 30 + label.length * 5.6
  }

  const undeclared = links.filter(l => l.declared === false).length
  const alt =
    `${links.length} connections between ${nodes.length} programs on this Mac` +
    (undeclared > 0 ? `; ${undeclared} between SkyEye services are not declared as dependencies.` : '.')
  return { svg: svg(size, size + 20, parts.join(''), alt), alt, undeclared }
}
