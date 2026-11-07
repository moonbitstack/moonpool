---
name: moonpool
description: "Keep a pool of reusable resources, such as database or network connections, in MoonBit with moonbitstack/moonpool: size and idle limits, idle and lifetime ages, a breaker, rate limit, backoff and load shedding in front of the backend, and power-of-two-choices, round-robin and weighted picks between targets. The pool does no I/O; it answers what the caller should do next. Use when writing a client that reuses connections or spreads calls over several backends."
---

# moonpool

```bash
moon add moonbitstack/moonpool
```

```moonbit
// moon.pkg
import {
  "moonbitstack/moonpool",
}
```

The pool never opens, closes or waits by itself. `take` answers what to do, and the caller does it and reports back. `now` is nanoseconds.

## Borrow, use, give back

```moonbit
fn borrow(
  pool : @moonpool.Pool[Int],
  now : Int64,
  open : () -> Int raise,
) -> Int? raise {
  match pool.take(now, roll=0.5) {
    Ready(conn) => Some(conn)
    Stale(_conn) => None // close it, then take again
    Make => {
      let conn = open() catch {
        e => {
          pool.unmade(now) // the slot it reserved is free again
          raise e
        }
      }
      pool.made(conn, now)
      Some(conn)
    }
    Wait | Later(_) | Shed => None // queue, wait, or fail fast
  }
}

fn give_back(pool : @moonpool.Pool[Int], conn : Int, now : Int64, broken : Bool) -> Unit {
  if broken {
    pool.drop(conn) // keeps the live count honest
  } else if !pool.give(conn, now) {
    () // more than `idle` are already waiting: close this one
  }
}
```

`roll` is a draw from `[0, 1)` for the breaker in front of the backend, if the pool has one.

## Limits and the ward

```moonbit
fn tuned() -> @moonpool.Pool[Int] {
  @moonpool.Pool::new(limits=@moonpool.Limits::new(size=32, idle=8))
}
```

| Limit | Preset | Decides |
|:--|:--|:--|
| `size` | 10 | live at once: idle, lent and being made |
| `idle` | 10 | how many may sit idle |
| `keep` | 30 min | how long an idle one may sit |
| `life` | forever | how long one may live at all |

`Ward::new(breaker?, bucket?, backoff?, shedder?)` puts moonward's guards in front of making new resources; a pool with an empty ward behaves as one without.

## Several backends

`pick(pools, now, first~, second~)` draws two pools and keeps the one that refuses less, then the one with fewer in use. `RoundRobin` and `Weighted` choose between targets that have no pool behind them.

## Things that catch people out

- `Stale` is handed back rather than skipped, so the caller closes an expired resource even when no eviction has run; `evict(now)` returns the expired idle ones in bulk.
- `give` does not reset a resource's birth: `life` retires a connection that has been reused all along.
- `Make` reserves a slot. Every `Make` must end in `made` or `unmade`, or the pool thinks a slot is in use for ever.
- There is no wait queue inside the pool: on `Wait`, the caller queues and calls `take` again when something is given back.
