import { useEffect, useRef, useState } from 'react'
import { collectionGroup, doc, getDoc, getDocs } from 'firebase/firestore'
import { onAuthStateChanged, signInWithPopup, signOut, GoogleAuthProvider } from 'firebase/auth'
import { auth, db } from './firebase'
import './App.css'

const COLORS = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7', '#9c755f', '#bab0ac']
const WEEK = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
// sample numbers for the landing page only (seconds per app)
const EXAMPLE_DAY = { chrome: 17400, Code: 4000, Spotify: 2400, explorer: 900, WindowsTerminal: 600 }

const iso = (y, m, d) => `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`
const hms = (s) => [Math.floor(s / 3600), Math.floor((s % 3600) / 60), s % 60].map((n) => String(n).padStart(2, '0')).join(':')

// apps for one machine, most recent day first; each app listed once with the date it was last used
// ponytail: scans in memory (day docs already loaded at sign-in), no extra reads; fine until thousands of days
function lastUsedApps(days, machine, limit = 3) {
  const seen = new Map()
  const mine = days.filter((d) => d.machine === machine).sort((a, b) => b.date.localeCompare(a.date))
  for (const d of mine) {
    for (const [name] of Object.entries(d.apps).sort((a, b) => b[1] - a[1])) {
      if (!seen.has(name)) seen.set(name, d.date)
    }
  }
  return [...seen].slice(0, limit)
}

// icon from public/icons/<app>.png, then <app>.svg; apps without either get icons/default.png
function AppIcon({ name }) {
  const [src, setSrc] = useState(`/icons/${name}.png`)
  return <img className="app-icon" src={src} alt="" onError={() => setSrc((s) => (s.endsWith('.png') ? `/icons/${name}.svg` : '/icons/default.png'))} />
}

function Pie({ apps }) {
  const entries = Object.entries(apps).sort((a, b) => b[1] - a[1])
  const total = entries.reduce((s, [, v]) => s + v, 0)
  if (!total) return <p>No usage recorded for this day.</p>

  let angle = -Math.PI / 2
  const slices = entries.map(([name, secs], i) => {
    const a = (secs / total) * 2 * Math.PI
    const x1 = 100 + 90 * Math.cos(angle), y1 = 100 + 90 * Math.sin(angle)
    angle += a
    const x2 = 100 + 90 * Math.cos(angle), y2 = 100 + 90 * Math.sin(angle)
    const d = `M100,100 L${x1},${y1} A90,90 0 ${a > Math.PI ? 1 : 0} 1 ${x2},${y2} Z`
    return { name, secs, d, color: COLORS[i % COLORS.length] }
  })

  return (
    <div className="pie">
      <svg viewBox="0 0 200 200" role="img" aria-label="App usage pie chart">
        {entries.length === 1
          ? <circle cx="100" cy="100" r="90" fill={COLORS[0]} />
          : slices.map((s) => <path key={s.name} d={s.d} fill={s.color} />)}
      </svg>
      <ul>
        {slices.map((s) => {
          const pct = Math.round((s.secs / total) * 100)
          return (
            <li key={s.name}>
              <AppIcon name={s.name} />
              <span>{s.name}</span>
              <span className="time">{hms(s.secs)} · {pct}%</span>
              <div className="bar-track"><span className="bar" style={{ width: `${pct}%`, background: s.color }} /></div>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

export default function App() {
  const [user, setUser] = useState(undefined) // undefined = still checking
  const [machines, setMachines] = useState([])
  const [machine, setMachine] = useState(() => localStorage.getItem('machine') ?? '')
  const [have, setHave] = useState(new Set()) // "machine/date" keys that have data
  const [days, setDays] = useState([]) // every loaded day: { machine, date, apps }
  const [month, setMonth] = useState(() => new Date())
  const [selected, setSelected] = useState(null)
  const [apps, setApps] = useState(null)
  const [error, setError] = useState('')
  const pickId = useRef(0) // latest click wins; older responses are ignored
  const [theme, setTheme] = useState(() => localStorage.getItem('theme') ??
    (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'))

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    localStorage.setItem('theme', theme)
  }, [theme])

  useEffect(() => onAuthStateChanged(auth, setUser), [])

  // one query: every day doc across machines -> machine list + highlighted dates
  useEffect(() => {
    if (!user) return
    getDocs(collectionGroup(db, 'days'))
      .then((snap) => {
        const names = [...new Set(snap.docs.map((d) => d.ref.parent.parent.id))].sort()
        setMachines(names)
        setHave(new Set(snap.docs.map((d) => `${d.ref.parent.parent.id}/${d.id}`)))
        setDays(snap.docs.map((d) => ({ machine: d.ref.parent.parent.id, date: d.id, apps: d.data().apps ?? {} })))
        setMachine((cur) => (names.includes(cur) ? cur : names[0] ?? ''))
      })
      .catch((e) => setError(`Could not load data (${e.code ?? e.message}). Check Firestore read rules.`))
  }, [user])

  useEffect(() => {
    if (machine) localStorage.setItem('machine', machine)
  }, [machine])

  if (user === undefined) return <main><p>Loading…</p></main>
  if (!user) return (
    <main className="landing">
      <header className="topbar">
        <strong className="brand">Activity tracker</strong>
        <button className="ghost" onClick={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}>
          {theme === 'dark' ? 'Light mode' : 'Dark mode'}
        </button>
      </header>

      <section className="hero">
        <h1>See where your time goes.</h1>
        <p className="lede">
          Activity tracker logs the app you use each minute on your PC and turns every day into a clear breakdown.
        </p>
        <button className="cta" onClick={() => signInWithPopup(auth, new GoogleAuthProvider()).catch((e) => setError(e.message))}>
          Sign in with Google
        </button>
        {error && <p className="error">{error}</p>}
      </section>

      <section className="feature">
        <div className="card">
          <Pie apps={EXAMPLE_DAY} />
        </div>
        <div className="steps">
          <h2>One breakdown per day</h2>
          <ol>
            <li><strong>Track.</strong> A background task samples the active app every minute.</li>
            <li><strong>Sync.</strong> Each sample updates that day in your Firebase database.</li>
            <li><strong>Review.</strong> Pick any day on the calendar to see where the time went.</li>
          </ol>
        </div>
      </section>

      <footer className="foot">The chart above uses example data.</footer>
    </main>
  )

  // click = query that day's doc from Firestore
  async function pick(key) {
    const id = ++pickId.current
    setSelected(key)
    setApps(null)
    setError('')
    try {
      const snap = await getDoc(doc(db, 'activity', machine, 'days', key))
      if (id !== pickId.current) return
      if (!snap.exists()) setError(`No data for ${key} on ${machine}.`)
      setApps(snap.data()?.apps ?? {})
    } catch (e) {
      if (id !== pickId.current) return
      setError(`Could not load ${key} (${e.code ?? e.message}).`)
      setApps({})
    }
  }

  const now = new Date()
  const today = iso(now.getFullYear(), now.getMonth(), now.getDate())
  const y = month.getFullYear(), m = month.getMonth()
  const cells = [...Array(new Date(y, m, 1).getDay()).fill(null), ...Array.from({ length: new Date(y, m + 1, 0).getDate() }, (_, i) => i + 1)]
  const shift = (n) => setMonth(new Date(y, m + n, 1))

  return (
    <main>
      <header className="topbar">
        <h1>Activity tracker</h1>
        <div className="tools">
          <label>
            Machine{' '}
            <select value={machine} onChange={(e) => { setMachine(e.target.value); setSelected(null); setApps(null) }}>
              {machines.map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
          </label>
          <button className="ghost" onClick={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}>
            {theme === 'dark' ? 'Light mode' : 'Dark mode'}
          </button>
          <button className="ghost" onClick={() => signOut(auth)}>Sign out</button>
        </div>
      </header>
      {error && <p className="error">{error}</p>}

      <div className="layout">
        <section className="card calendar">
          <header>
            <button onClick={() => shift(-1)}>‹</button>
            <strong>{month.toLocaleString('default', { month: 'long', year: 'numeric' })}</strong>
            <button onClick={() => shift(1)}>›</button>
          </header>
          <div className="grid">
            {WEEK.map((w) => <div key={w} className="dow">{w}</div>)}
            {cells.map((d, i) => {
              if (!d) return <div key={i} />
              const key = iso(y, m, d)
              const has = have.has(`${machine}/${key}`)
              return (
                <button
                  key={i}
                  className={`day ${has ? 'has' : ''} ${selected === key ? 'sel' : ''} ${key === today ? 'today' : ''}`}
                  disabled={!has && key !== today}
                  onClick={() => pick(key)}
                >
                  {d}
                </button>
              )
            })}
          </div>
        </section>

        <section className="card detail">
          {!selected && <p className="empty">Select a highlighted date or today.</p>}
          {selected && (
            <>
              <div className="detail-head">
                <h2>{selected}</h2>
                {apps && <span className="total">{hms(Object.values(apps).reduce((s, v) => s + v, 0))} active</span>}
              </div>
              <div className="last-used">
                <span className="label">Last used:</span>
                {lastUsedApps(days, machine).map(([name, date]) => (
                  <span key={name} className="chip" title={`last used ${date}`}>
                    <AppIcon name={name} />{name}
                  </span>
                ))}
              </div>
              {apps === null ? <p className="empty">Loading…</p> : <Pie key={selected} apps={apps} />}
            </>
          )}
        </section>
      </div>
    </main>
  )
}
