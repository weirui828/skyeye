// Helpers the chart modules share. D3 is loaded before the modules as a global.
//
// Every name, title and path in a scan comes from other programs on the Mac:
// all of it goes through esc() before it reaches the page.

export const d3 = window.d3

export const DAY = 86_400_000
export const RISK_ORDER = ['high', 'medium', 'low', 'info']
export const RISK_LABEL = { high: 'High', medium: 'Medium', low: 'Low', info: 'Info' }
export const RADIUS = { high: 7, medium: 6, low: 5, info: 4 }

// Each well-known service keeps its own categorical slot whatever else is
// on screen; everything else, the local network included, is gray.
export const OWNER_SLOT = {
  Google: 0, 'Google Cloud': 0, Anthropic: 1, Microsoft: 2, Cloudflare: 3,
  GitHub: 4, AWS: 5, 'AWS CloudFront': 5, Apple: 6, Meta: 7,
}
// An owner's name comes from DNS or a registry: it is looked up as its own key only, so a name such as
// "constructor" finds nothing rather than something every object inherits.
export const ownerClass = owner => (Object.hasOwn(OWNER_SLOT, owner) ? `s${OWNER_SLOT[owner]}` : 'sx')

export function esc(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

export function svg(width, height, body, alt, shown = width) {
  const scale = shown / width
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${shown.toFixed(0)}" height="${(height * scale).toFixed(0)}" ` +
    `viewBox="0 0 ${width} ${height}" role="img" aria-label="${esc(alt)}">${body}</svg>`
  )
}

export const cut = (text, n) => (text.length > n ? `${text.slice(0, Math.max(1, n - 1))}…` : text)

export function portsOf(s) {
  const list = s.ports.map(p => p.port)
  return list.length <= 3 ? list.join(', ') : `${list.slice(0, 2).join(', ')} +${list.length - 2}`
}

export function memory(kb) {
  const mb = kb / 1024
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.max(1, Math.round(mb))} MB`
}

export function bytes(n) {
  if (n < 1024) return `${Math.round(n)} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(n < 10_240 ? 1 : 0)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(n < 10 * 1024 ** 2 ? 1 : 0)} MB`
  return `${(n / 1024 ** 3).toFixed(1)} GB`
}

export function uptime(ms) {
  const m = Math.floor(ms / 60_000)
  if (m < 60) return `${Math.max(1, m)}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ${m % 60}m`
  const d = Math.floor(h / 24)
  return d < 7 ? `${d}d ${h % 24}h` : `${d}d`
}

export const isStale = (s, now) => s.section === 'servers' && now - s.startedAt > DAY

export function tip(s, now) {
  return esc(
    `${s.name} · ${portsOf(s)}\n${RISK_LABEL[s.risk]} risk: ${s.reasons.join('; ')}\n` +
      `${s.process} · up ${uptime(now - s.startedAt)} · ${memory(s.rssKb)} · by ${s.startedBy}`,
  )
}

// What the treemap and the connection map group a listening program under.
export function groupOf(s) {
  if (s.section === 'apps') return 'Apps'
  if (s.section === 'system') return 'macOS'
  return s.project ?? 'Other'
}

// Projects take categorical slots in name order, the same in every chart;
// apps, macOS and the rest stay gray.
export function projectSlots(programs) {
  const projects = [...new Set(programs.filter(s => s.section === 'servers' && s.project).map(s => s.project))].sort()
  return group => {
    const i = projects.indexOf(group)
    return i === -1 || i > 7 ? 'sx' : `s${i}`
  }
}
