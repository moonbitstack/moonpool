<h1 align="center">moonpool</h1>

<p align="center"><b>A pool that answers, and leaves the acting to you.</b></p>

<p align="center">
  Which resource to lend, when to open another, which to retire, and when to refuse —<br>
  with the clock and the randomness passed in, so every run is reproducible.
</p>

<p align="center">
  <a href="https://moonbitstack.github.io/moonpool/">Home</a> ·
  <a href="https://moonbitstack.github.io/moonpool/guide.html">Guide</a> ·
  <a href="https://moonbitstack.github.io/moonpool/api.html">API</a> ·
  <a href="https://mooncakes.io/docs/moonbitstack/moonpool">mooncakes</a>
</p>

---

```moonbit
let pool : @moonpool.Pool[Conn] = @moonpool.Pool::new(
  limits=@moonpool.Limits::new(size=20),
)
let now = 0L
match pool.take(now, roll=0.42) {
  Ready(conn) => ignore(pool.give(conn, now))   // lend, then take it back
  Stale(conn) => ignore(conn)                   // too old: close it, ask again
  Make => pool.made(1, now)                     // open one; unmade(now) if that fails
  Wait => ()                                    // all in use: queue the caller
  Later(wait) => ignore(wait)                   // making is held back this long
  Shed => ()                                    // fail now: the backend or the host said no
}
```

## Six answers

| | Means | What the caller does |
|:--|:--|:--|
| `Ready(conn)` | An idle resource, the most recently returned one | Use it, then `give` it back |
| `Stale(conn)` | An idle resource past its age | Close it, then `take` again |
| `Make` | There is room, and it is reserved | Open one, then `made` — or `unmade` if that fails |
| `Wait` | Every live slot is in use | Queue the caller; the pool has no queue of its own |
| `Later(span)` | Making is held back | Try again after that span |
| `Shed` | Refuse | Fail fast |

## The four limits

| | Preset | What it decides |
|:--|:--|:--|
| `size` | 10 | How many may be live at once: idle, lent, and being made |
| `idle` | 10 | How many may sit idle; `give` answers `false` when that many are already there |
| `keep` | 30 min | How long an idle resource may sit before it is retired |
| `life` | `forever` | How long a resource may live at all, however busy it has been |

Zero means no limit for the two ages. `Limits::new` takes any of them by name, and
`{ ..limits, size: 32 }` changes one and keeps the rest.

## Nothing is lost

`take` hands an idle resource past its age back as `Stale` rather than skipping it, so a
caller closes it whether or not the eviction timer has run. A resource is recognised on its
way back by identity, not by arrival: `give` does not reset its birth, so `life` retires a
connection that has been reused all along. A broken one goes to `drop`, which is what keeps
the live count honest.

## Around the pool

A ward can stand in front of the backend: a breaker that refuses new connections at the rate
a failing one deserves, a bucket that spaces makes out, backoff after a make that failed, and
a shedder that stops lending while the host is hot. Every part is optional, and a pool with
an empty ward behaves exactly as a pool without one. `pick` chooses between several pools to
one service: two drawn at random, the one that refuses less, then the one with fewer in use.

## Install

```bash
moon add moonbitstack/moonpool
```

## See it run

```bash
moon run examples/sim
```

A synthetic client drives a real pool for twenty-four seconds and prints one row a second:
how many lanes were lent, how many sat idle, and how many callers had to wait.

The same engine, compiled to JavaScript, runs the
[simulator](https://moonbitstack.github.io/moonpool/sim.html) — the chart, the boards and the
refusal line are the pool's own answers, not a mock.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
