export const flowRate = link => link.sent + link.received

export function flowOffset(id) {
  let hash = 2166136261
  for (const char of id) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619)
  return (hash >>> 0) / 4294967296
}

export function flowPhase(time, speed, id, reverse = false) {
  const duration = Math.max(2.4, 7.5 - Math.log10(1 + speed) * 0.65) * 1000
  const phase = (time / duration + flowOffset(id) + (reverse ? 0.43 : 0)) % 1
  return reverse ? 1 - phase : phase
}

export function shortName(node, cap = 25) {
  const name = node.members ? `Others · ${node.members.length}` : node.name
  if (name.includes(':') && /^[0-9a-f:]+$/i.test(name) && name.length > cap) {
    const parts = name.split(':').filter(Boolean)
    return `${parts.slice(0, 2).join(':')}:…:${parts.at(-1)}`
  }
  return name.length > cap ? `${name.slice(0, cap - 1)}…` : name
}
