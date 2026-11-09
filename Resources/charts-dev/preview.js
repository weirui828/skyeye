// Draws the charts outside the app. live.json (a real scan, never committed) wins over the demo data.
// ?tab=ports|traffic|processes picks the tab; ?select=<pid> selects a program; ?demo keeps to the demo data.
const load = async name => {
  const response = await fetch(name)
  if (!response.ok) throw new Error(name)
  return response.json()
}
const query = new URLSearchParams(location.search)
const { scan, history } = await (query.has('demo') ? load('sample.json') : load('live.json').catch(() => load('sample.json')))
window.SkyEyeCharts.show(query.get('tab') ?? 'ports')
window.SkyEyeCharts.render(scan)
window.SkyEyeCharts.history(history)
if (query.get('select')) window.SkyEyeCharts.select(Number(query.get('select')))
