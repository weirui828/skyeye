const programs = ['Google Chrome', 'ChatGPT', 'Claude Code', 'Google Drive', 'Messages', 'Adobe Creative Cloud', 'Terminal', 'SkyEye', 'petshop-frontend', 'petshop-backend', 'PostgreSQL', 'Docker', 'ssh', 'Safari', 'Music']
const destinations = ['Google', 'Cloudflare', 'Anthropic', 'AWS', 'Apple', 'GitHub', 'Local network', 'Google Cloud', 'AWS CloudFront']
const nodes = [
  ...programs.map((name, i) => ({ id: `p${i}`, name, kind: i === 4 ? 'system' : 'program', pids: [1000 + i] })),
  ...destinations.map((name, i) => ({ id: `r${i}`, name, kind: 'remote', pids: [] })),
]
const connections = [[0, 0], [0, 1], [0, 3], [1, 1], [2, 2], [3, 0], [4, 4], [5, 3], [6, 5], [7, 5], [9, 7], [11, 6], [12, 6], [13, 1], [14, 4], [0, 8]]
let timer = null, step = 0
function sample() {
  const links = connections.filter((_, i) => i !== 15 || step % 16 < 10).map(([p, r], i) => ({
    id: `e${i}`, from: `p${p}`, to: `r${r}`, local: false, connections: 2 + i % 8,
    sent: i === 4 ? 0 : Math.round((1 + Math.sin(step / 3 + i)) * (i === 5 ? 55_000 : 1400)),
    received: i === 4 ? 0 : Math.round((1 + Math.cos(step / 4 + i)) * (i === 0 ? 220_000 : 3400)),
    ports: [443], hosts: [`${destinations[r].toLowerCase().replaceAll(' ', '-')}.example`], protocols: ['TCP'],
  }))
  for (const [i, [a, b, port]] of [[0, 8, 3000], [8, 9, 8000], [9, 10, 5432], [6, 11, 2375], [12, 11, 22]].entries()) {
    links.push({ id: `l${i}`, from: `p${a}`, to: `p${b}`, local: true, connections: i + 1,
      sent: 600 + Math.round((1 + Math.sin(step / 2 + i)) * 2000), received: 1500 + Math.round((1 + Math.cos(step / 2 + i)) * 4000),
      ports: [port], hosts: ['127.0.0.1'], protocols: ['TCP'] })
  }
  return {
    at: Date.now(), warmingUp: false, nodes, links,
    sent: links.filter(l => !l.local).reduce((sum, l) => sum + l.sent, 0),
    received: links.filter(l => !l.local).reduce((sum, l) => sum + l.received, 0),
    internalRate: links.filter(l => l.local).reduce((sum, l) => sum + l.sent + l.received, 0),
  }
}
function tick() { step += 1; const value = sample(); window.SkyEyeCharts.render(value); return value }
window.SkyEyeCharts.show('monitoring')
tick()
timer = setInterval(tick, 1000)
window.SkyEyeMonitoringDemo = {
  tick,
  pause() { clearInterval(timer); timer = null },
  resume() { if (!timer) timer = setInterval(tick, 1000) },
  sample,
}
