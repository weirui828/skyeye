import test from 'node:test'
import assert from 'node:assert/strict'
globalThis.window = { d3: null }
const { projectActivity } = await import('../../Resources/charts/monitoring.js')

const edge = (from, to, local = false, sent = 100) => ({ id: `${from}-${to}`, from, to, local, sent, received: 20, connections: 2, ports: [local ? 5432 : 443], hosts: ['example.test'], protocols: ['TCP'] })
const sample = {
  nodes: [{ id: 'app', name: 'App', kind: 'program', pids: [1] }, { id: 'db', name: 'Database', kind: 'program', pids: [2] }, { id: 'web', name: 'Web', kind: 'remote', pids: [] }],
  links: [edge('app', 'db', true), edge('app', 'web'), edge('db', 'web')],
}

test('internal and external traffic share the same program node', () => {
  const graph = projectActivity(sample)
  assert.equal(graph.nodes.filter(n => n.id === 'app').length, 1)
  assert.equal(graph.links.length, 3)
  assert.equal(graph.connections, 6)
  assert.equal(graph.links.reduce((sum, l) => sum + l.sent + l.received, 0), 360)
})

test('host/port search and focus preserve matching connections', () => {
  assert.equal(projectActivity(sample, { query: '5432' }).links.length, 1)
  assert.equal(projectActivity(sample, { query: 'EXAMPLE.TEST' }).links.length, 3)
  assert.equal(projectActivity(sample, { focus: 'db' }).links.length, 2)
  assert.equal(projectActivity(sample, { query: 'not found' }).nodes.length, 0)
})

test('large maps group nodes without dropping traffic or connections', () => {
  const large = { nodes: [sample.nodes[2]], links: [] }
  for (let i = 0; i < 100; i++) {
    large.nodes.push({ id: `p${i}`, name: `Program ${i}`, kind: 'program', pids: [i] })
    large.links.push(edge(`p${i}`, 'web', false, i))
  }
  const graph = projectActivity(large)
  assert.equal(graph.nodes.length, 14)
  assert.equal(graph.connections, 200)
  assert.equal(graph.nodes.find(n => n.id === 'group:program').members.length, 88)
  assert.equal(graph.links.reduce((sum, l) => sum + l.sent, 0), 4950)
  const focused = projectActivity(large, { focus: 'p0' })
  assert.equal(focused.nodes.length, 2)
  assert.equal(focused.nodes.some(n => n.id === 'p0'), true)
})

const { layoutActivity } = await import('../../Resources/charts/monitoring.js')
test('external endpoints occupy opposite semicircles and internal links get their own inset', () => {
  const graph = projectActivity(sample)
  const layout = layoutActivity(graph, 958, 580)
  const app = layout.nodes.find(n => n.key === 'external:app')
  const remote = layout.nodes.find(n => n.key === 'external:web')
  const localApp = layout.nodes.find(n => n.key === 'local:app')
  assert(app.x < app.cx)
  assert(remote.x > remote.cx)
  assert(localApp.compact)
  assert(localApp.cx > remote.cx)
  assert(localApp.cy < remote.cy)
  assert.equal(layout.arcs.length, 2)
  assert.equal(layout.circles.length, 1)
  assert.equal(layout.nodes.filter(n => n.id === 'app').length, 2)
  for (const n of layout.nodes) {
    assert(n.x >= 0 && n.x <= 958)
    assert(n.y >= 0 && n.y <= 580)
  }
})

test('internal-only view expands the local circle without external semicircles', () => {
  const layout = layoutActivity(projectActivity(sample, { query: '5432' }), 655, 400)
  assert.equal(layout.arcs.length, 0)
  assert.equal(layout.circles.length, 1)
  assert(layout.nodes.every(n => !n.compact))
  assert(layout.circles[0].r > 100)
})

const { sphereNodes, sphereCurve, rotatePoint, projectPoint } = await import('../../Resources/charts/globe.js')
test('one sphere contains each program once, with a smaller local cap', () => {
  const graph = projectActivity(sample)
  const nodes = sphereNodes(graph.nodes)
  assert.equal(nodes.length, graph.nodes.length)
  assert.equal(nodes.filter(n => n.id === 'app').length, 1)
  for (const node of nodes) {
    assert(Math.abs(Math.hypot(...node.position) - 1) < 1e-10)
    if (node.kind === 'remote') assert(node.position[0] > -0.28)
    else assert(node.position[0] < -0.28)
  }
  assert.deepEqual(sphereNodes([...graph.nodes].reverse()), nodes)
})

test('all traffic curves, including self-connections, stay inside the sphere', () => {
  const nodes = sphereNodes(projectActivity(sample).nodes)
  for (const a of nodes) for (const b of nodes) for (const local of [false, true]) {
    assert.deepEqual(sphereCurve(a.position, b.position, 0, local), a.position)
    assert.deepEqual(sphereCurve(a.position, b.position, 1, local), b.position)
    for (let step = 0; step <= 100; step++) {
      const point = sphereCurve(a.position, b.position, step / 100, local)
      assert(point.every(Number.isFinite))
      assert(Math.hypot(...point) <= 1 + 1e-10)
    }
  }
})

test('rotation preserves the sphere and perspective distinguishes front from back', () => {
  const point = [0.4, 0.5, Math.sqrt(0.59)]
  for (const yaw of [0, 0.7, Math.PI, 5]) for (const pitch of [-Math.PI / 2, 0, 0.6, Math.PI / 2]) {
    assert(Math.abs(Math.hypot(...rotatePoint(point, yaw, pitch)) - 1) < 1e-10)
    const projected = projectPoint(point, { yaw, pitch, radius: 200 })
    assert(Object.values(projected).every(Number.isFinite))
  }
  assert(projectPoint([0.5, 0, 0.5]).scale > projectPoint([0.5, 0, -0.5]).scale)
})

test('new destinations do not displace existing nodes on the sphere', () => {
  const initial = sphereNodes(projectActivity(sample).nodes)
  const expanded = sphereNodes([...sample.nodes, { id: 'new', name: 'New destination', kind: 'remote', pids: [] }], initial)
  for (const node of initial) assert.deepEqual(expanded.find(n => n.id === node.id).position, node.position)
  const next = expanded.find(n => n.id === 'new')
  assert(next.position[0] > -0.28)
  assert(Math.abs(Math.hypot(...next.position) - 1) < 1e-10)
})

const { frontSurface, sphereLocalAt } = await import('../../Resources/charts/globe.js')
test('the smooth sphere material projects exactly onto the surface and its two regions', () => {
  for (const u of [-0.9, -0.4, 0, 0.4, 0.9]) for (const v of [-0.3, 0, 0.3]) {
    const point = frontSurface(u, v)
    assert(point)
    assert(Math.abs(Math.hypot(...point) - 1) < 1e-10)
    const screen = projectPoint(point)
    assert(Math.abs(screen.x - u) < 1e-10)
    assert(Math.abs(screen.y - v) < 1e-10)
  }
  assert.equal(frontSurface(2, 2), null)
  for (const point of [[-0.8, 0.6, 0], [0.6, 0, 0.8]]) {
    for (const yaw of [0, 0.7, 2]) for (const pitch of [-0.5, 0.3]) {
      assert.equal(sphereLocalAt(rotatePoint(point, yaw, pitch), yaw, pitch), point[0] < -0.28)
    }
  }
})

test('recently active nodes remain stable while displayed traffic uses the current counters', () => {
  const nodes = Array.from({ length: 16 }, (_, i) => ({ id: `p${i}`, name: `Program ${i}`, kind: 'program', pids: [i] }))
  nodes.push({ id: 'web', name: 'Web', kind: 'remote', pids: [] })
  const links = nodes.filter(n => n.id !== 'web').map(n => edge(n.id, 'web', false, n.id === 'p15' ? 10000 : 10))
  const first = projectActivity({ at: 1000, nodes, links })
  const next = projectActivity({ at: 2000, nodes, links: links.map(l => ({ ...l, sent: 0, received: 0 })) }, { previous: first.nodes })
  assert(next.nodes.some(n => n.id === 'p15'))
  assert.equal(next.links.reduce((sum, l) => sum + l.sent + l.received, 0), 0)
  assert.equal(next.connections, links.length * 2)
})

const { flowPhase } = await import('../../Resources/charts/flow-style.js')
test('flow motion is desynchronized, directional and bounded', () => {
  const phase = flowPhase(1000, 2000, 'first')
  assert(phase >= 0 && phase <= 1)
  assert.notEqual(phase, flowPhase(1000, 2000, 'second'))
  assert.notEqual(phase, flowPhase(1100, 2000, 'first'))
})

const { SPHERE_RIM } = await import('../../Resources/charts/globe.js')
test('material rays remain finite at every angle along the projected silhouette', () => {
  for (let step = 0; step < 1000; step++) {
    const angle = step / 1000 * Math.PI * 2
    const point = frontSurface(Math.cos(angle) * SPHERE_RIM * 0.999999, Math.sin(angle) * SPHERE_RIM * 0.999999)
    assert(point && point.every(Number.isFinite))
    assert.equal(frontSurface(Math.cos(angle) * SPHERE_RIM * 1.0001, Math.sin(angle) * SPHERE_RIM * 1.0001), null)
  }
})
