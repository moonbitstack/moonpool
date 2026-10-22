# moonpool

Resource pools for MoonBit: which resource to hand out, when to make another, and which to let go. A ward of [moonward](https://github.com/moonbitstack/moonward)'s parts can stand in front of the backend: a breaker that stops new connections to a failing backend, a token bucket that spaces them out, backoff after a failed one, and a shedder that stops lending while the process is overloaded.

```moonbit
let pool : @moonpool.Pool[Int32] = @moonpool.Pool::new(
  limits=@moonpool.Limits::new(size=20),
  ward=@moonpool.Ward::new(
    breaker=@moonward.Breaker::new(),
    backoff=@moonward.backoff,
  ),
)
let now = 0L
match pool.take(now, roll=0.42) {
  Ready(conn) => ignore(pool.give(conn, now)) // use it, then give it back
  Stale(conn) => ignore(conn) // too old to use: close it and take again
  Make => pool.made(1, now) // open one, or call pool.unmade(now) if that fails
  Wait => () // all in use: queue the caller
  Later(wait) => ignore(wait) // making is held back this long
  Shed => () // fail fast: the backend is refusing, or this process is overloaded
}
```

## No I/O, and that is the point

Nothing here opens, closes, sleeps or reads a clock. The pool says what to do with a resource and the caller does it. Time is whatever the caller's clock reads, in nanoseconds; `roll` is a draw from `[0, 1)` for the breaker and for backoff jitter; `cpu` is the processor load in thousandths, for the shedder. Passing all three in is what makes every sequence reproducible: a test drives a pool through an hour in a few lines.

## The pieces

| | What it answers |
|:--:|:--|
| `Pool[T]` | Which resource to hand out, whether to make another, which have sat or lived long enough to let go |
| `Ward` | What stands in front of the backend; every part optional, the preset `ward` has none |
| `pick` | Which of several pools to one service to take from: two drawn at random, the one whose breaker refuses less, then the one with fewer in use |
| `Backoff`, `Bucket`, `Gate`, `Sliding` | Re-exported from moonward, where they now live |

## What a ward does

| Part | When | Answer |
|:--:|:--|:--|
| shedder | before lending at all | `Shed` while the process is hot and has more in flight than it has shown it can finish |
| backoff | before making, after a failed `make` | `Later(span)` until the delay has passed; the delay grows with each failure in a row |
| bucket | before making | `Later(span)` until the bucket has a token, so reconnections do not arrive at once |
| breaker | before making | `Shed` with the probability the breaker gives a failing backend |

`made` tells the breaker a connection succeeded and clears the backoff; `unmade` tells it one failed. The shedder treats a lent resource as a call in flight and the time from `take` to `give` as its response time, which is what go-zero's adaptive shedder measures.

## The defaults, and where they come from

`Limits`: ten live, ten idle, thirty minutes before an idle one is dropped, no maximum age. Ten is HikariCP's and Go's `database/sql` default; keeping `idle` equal to `size` is `database/sql`'s behaviour, so a pool that grew under load does not immediately throw the connections away. The ward's parts carry moonward's presets, which are go-zero's and gRPC's.

## A note on the newest-first order

A pool hands out the most recently returned resource, not the oldest. A warm connection is likelier to still be good, and handing out the newest lets the oldest age past `keep` and be evicted, which is how a pool shrinks again after a burst.

## A resource is never lost, and never younger than it is

`take` hands an idle resource that is past its age back as `Stale` rather than skipping it, so the caller closes it whether or not the eviction timer has run. The pool remembers when each lent resource was made, recognising it by identity on the way back, so `give` does not reset its age and `life` retires a connection that has been reused all along.

## Install

```bash
moon add moonbitstack/moonpool
```

A ward's parts come from moonward, so a pool with a ward needs `moon add moonbitstack/moonward` as well.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
