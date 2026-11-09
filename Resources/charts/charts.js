// The ports page's chart board. SkyEye hands over a scan (and, between scans,
// the traffic history); the board draws the cards of the tab that is showing.
// Colors live in charts.css so light and dark follow the app.

import { beeswarmSvg, ringsSvg, timelineSvg, treemapSvg } from './ports.js'
import { bundleSvg, treeSvg } from './processes.js'
import { flowSvg, mountSunburst, ridgelineSvg } from './traffic.js'
import { bytes, memory } from './util.js'

const board = document.getElementById('board')
const tipBox = document.getElementById('tip')
const state = {
  scan: null,
  history: null,
  selected: null,
  tab: 'ports',
  width: 0,
  // what the reader did to a chart, kept across redraws
  sunburst: { focus: [] },
  tree: { folded: new Map() },
}

const post = message => window.webkit?.messageHandlers?.skyeye?.postMessage(message)

function note(el, text) {
  const p = document.createElement('p')
  p.className = 'note'
  p.textContent = text
  el.replaceChildren(p)
}

// A card draws into `el` and returns its heading, [title, caption]; null when
// it has nothing to show and should be left out.
const fill = (el, chart, heading) => {
  if (!chart) return null
  el.innerHTML = chart.svg
  return heading(chart)
}

const CARDS = {
  ports: [
    { id: 'rings', draw: (el, c) => fill(el, ringsSvg(c.programs, c.now, Math.min(c.width, 520)), () => ['How far each program can be reached', 'one dot per program']) },
    { id: 'beeswarm', draw: (el, c) => fill(el, beeswarmSvg(c.programs, c.now, c.width), () => ['Where the ports are', 'one dot per port, by number']) },
    { id: 'timeline', draw: (el, c) => fill(el, timelineSvg(c.programs.filter(s => s.section === 'servers'), c.now, c.width), () => ['How long servers have run', 'last 7 days · dashed line is 1 day ago']) },
    { id: 'treemap', draw: (el, c) => fill(el, treemapSvg(c.programs, c.now, c.width), chart => [`${memory(chart.kb)} of memory`, 'by project']) },
  ],
  traffic: [
    { id: 'flow', draw: (el, c) => fill(el, flowSvg(c.talkers, c.width), chart => ['Who programs talk to', `${c.talkers.length} programs → ${chart.services} services, by connections`]) },
    {
      id: 'sunburst',
      draw: (el, c) => {
        const chart = mountSunburst(el, c.scan.traffic, c.width, state.sunburst)
        return chart && [`${bytes(chart.total)} over open connections`, 'by service, program, address · click a ring to zoom']
      },
    },
    {
      id: 'ridgeline',
      draw: (el, c) => {
        const chart = ridgelineSvg(state.history, c.width)
        if (chart) return fill(el, chart, () => ['Traffic over time', `last ${Math.round(chart.span / 60_000) || 1} min · bytes per second, by program`])
        note(el, 'Collecting samples: one every 10 seconds while this window is open.')
        return ['Traffic over time', 'bytes per second, by program']
      },
    },
  ],
  processes: [
    { id: 'tree', draw: (el, c) => fill(el, treeSvg(c.scan.tree, c.programs, c.width, state.tree), chart => ['Who started what', `${chart.listeners} listening programs · click a branch to fold it`]) },
    {
      id: 'bundle',
      draw: (el, c) => {
        const chart = bundleSvg(c.scan.local, c.programs, c.width)
        if (chart) {
          return fill(el, chart, () => [
            'Connections inside this Mac',
            chart.undeclared > 0 ? `${chart.undeclared} not declared as dependencies · point at a program` : 'which program has which port open · point at a program',
          ])
        }
        note(el, 'No program on this Mac has another program’s port open right now.')
        return ['Connections inside this Mac', 'which program has which port open']
      },
    },
  ],
}
const EMPTY = {
  ports: 'Nothing is listening.',
  traffic: 'No program is talking to another machine right now.',
  processes: 'Nothing is listening.',
}

function context() {
  const scan = state.scan
  // the board's padding, then each card's border and padding
  const width = Math.max(300, Math.floor(board.clientWidth) - 24 - 28)
  return { scan, width, now: scan.scannedAt, programs: scan.programs ?? [], talkers: scan.outgoing ?? [] }
}

function section(card, c) {
  const body = document.createElement('div')
  body.className = 'chart'
  const heading = card.draw(body, c)
  if (!heading) return null
  const el = document.createElement('section')
  el.className = 'card'
  el.id = `card-${card.id}`
  const h = document.createElement('h2')
  const caption = document.createElement('span')
  h.textContent = heading[0]
  caption.textContent = heading[1]
  h.append(caption)
  el.append(h, body)
  return el
}

function draw() {
  if (!state.scan) return
  const c = context()
  state.width = c.width
  const cards = (CARDS[state.tab] ?? CARDS.ports).map(card => section(card, c)).filter(Boolean)
  if (cards.length > 0) {
    board.replaceChildren(...cards)
  } else {
    const empty = document.createElement('p')
    empty.className = 'empty'
    empty.textContent = EMPTY[state.tab] ?? EMPTY.ports
    board.replaceChildren(empty)
  }
  tipBox.hidden = true
  hovered = null
  mark()
}

// One card again, the others left as they are: a zoomed sunburst is not disturbed by a traffic sample.
function redraw(id) {
  const card = (CARDS[state.tab] ?? []).find(x => x.id === id)
  const old = document.getElementById(`card-${id}`)
  if (!state.scan || !card || !old) return
  const fresh = section(card, context())
  if (fresh) old.replaceWith(fresh)
  else old.remove()
  mark()
}

function mark() {
  for (const el of board.querySelectorAll('.sel')) el.classList.remove('sel')
  if (state.selected === null) return
  for (const el of board.querySelectorAll(`[data-pid="${state.selected}"]`)) el.classList.add('sel')
}

function render(scan) {
  state.scan = scan
  draw()
}

function history(samples) {
  state.history = samples
  redraw('ridgeline')
}

function select(pid) {
  state.selected = pid ?? null
  mark()
}

function show(tab) {
  if (!CARDS[tab] || tab === state.tab) return
  state.tab = tab
  window.scrollTo(0, 0)
  draw()
}

// Pointing at a program in the connection map lights its lines: what it connects to, and what reaches it.
let hovered = null
function light(node) {
  const id = node?.getAttribute('data-node') ?? null
  if (id === hovered) return
  hovered = id
  for (const el of board.querySelectorAll('.wire.out, .wire.in')) el.classList.remove('out', 'in')
  for (const el of board.querySelectorAll('.peer.lit')) el.classList.remove('lit')
  board.classList.toggle('lighting', id !== null)
  if (id === null) return
  node.classList.add('lit')
  for (const wire of board.querySelectorAll('.wire[data-from]')) {
    const from = wire.getAttribute('data-from')
    const to = wire.getAttribute('data-to')
    if (from !== id && to !== id) continue
    wire.classList.add(from === id ? 'out' : 'in')
    for (const peer of board.querySelectorAll('.peer')) {
      if (peer.getAttribute('data-node') === (from === id ? to : from)) peer.classList.add('lit')
    }
  }
}

document.addEventListener('mousemove', e => {
  const target = e.target instanceof Element ? e.target : null
  light(target?.closest('[data-node]') ?? null)
  const el = target?.closest('[data-tip]')
  if (!el) {
    tipBox.hidden = true
    return
  }
  tipBox.textContent = el.getAttribute('data-tip')
  tipBox.hidden = false
  const box = tipBox.getBoundingClientRect()
  const x = Math.min(e.clientX + 14, window.innerWidth - box.width - 6)
  const y = e.clientY + 18 + box.height > window.innerHeight ? e.clientY - box.height - 10 : e.clientY + 18
  tipBox.style.transform = `translate(${Math.max(6, x)}px, ${Math.max(6, y)}px)`
})
document.addEventListener('mouseleave', () => {
  tipBox.hidden = true
  light(null)
})
document.addEventListener('click', e => {
  const target = e.target instanceof Element ? e.target : null
  const fold = target?.closest('[data-fold]')
  if (fold) {
    const pid = Number(fold.getAttribute('data-fold'))
    state.tree.folded.set(pid, fold.querySelector('.knot.folded') === null)
    redraw('tree')
    return
  }
  const el = target?.closest('[data-pid]')
  if (!el) return
  const pid = Number(el.getAttribute('data-pid'))
  select(pid)
  post({ type: 'select', pid })
})

let frame = 0
new ResizeObserver(() => {
  cancelAnimationFrame(frame)
  frame = requestAnimationFrame(() => {
    if (Math.max(300, Math.floor(board.clientWidth) - 52) !== state.width) draw()
  })
}).observe(board)

window.SkyEyeCharts = { render, history, select, show }
post({ type: 'ready' })
