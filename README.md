# moonpool

Resource pools, backoff and flow control. Three kinds of bookkeeping that every
client and every server writes, and that everyone writes slightly differently.

```moonbit
// A pool that hands out what it has and says when to make or wait for more.
let pool : @moonpool.Pool[Conn] = @moonpool.Pool::new(
  limits=@moonpool.Limits::new(size=20),
)
match pool.take(now) {
  Ready(conn) => use(conn)
  Make => use(open())
  Wait => queue()
}

// A retry policy that says how long to wait, and when to stop.
let policy = @moonpool.Backoff::new(attempts=5)
if policy.more(tries) { sleep(policy.delay(tries, random=draw())) }

// A rate limit, a quota and a concurrency limit.
@moonpool.Bucket::new(100.0, burst=200.0).take(now)
@moonpool.Window::new(1000, @moondate.Span::new(days=1L)).take(now)
@moonpool.Gate::new(64).enter()
```

## No I/O, and that is the point

Nothing here opens, closes, sleeps or reads a clock. The pool says *what* to do with
a resource and the caller does it; the backoff says *how long* and the caller sleeps
it; the limiter says *whether* and the caller answers. Time is passed in as whatever
the caller's own clock read, in nanoseconds.

That is not purity for its own sake. It is what makes every sequence here
reproducible: a test drives a pool through an hour in three lines, and a retry
schedule with the same draws is the same schedule twice. A library that read the
clock itself could only be tested by waiting.

## The pieces

| | What it answers |
|:--:|:--|
| `Pool[T]` | Which resource to hand out, whether to make another, which have sat or lived long enough to let go |
| `Backoff` | How long before the next try, and whether there should be one |
| `Bucket` | Whether this request is within a rate, and how long until it would be |
| `Window` | Whether it is within a quota — a thousand a day is a window, not a rate |
| `Gate` | Whether there is room right now, which has nothing to do with time |

## The defaults, and where they come from

`Limits`: ten live, ten idle, thirty minutes before an idle one is dropped, no
maximum age. Ten is HikariCP's and Go's `database/sql` default; keeping `idle` equal
to `size` is `database/sql`'s behaviour, so a pool that grew under load does not
immediately throw the connections away.

`Backoff`: three attempts, 100 ms doubling to a 1 s ceiling, full jitter. Those are
gRPC's documented retry defaults, and gRPC sleeps a value drawn uniformly from
`[0, cap]`, which is what full jitter is.

The four jitter strategies are the ones AWS's *Exponential Backoff and Jitter*
names and measures. `Full` is the default because that article's own measurements
put it ahead; `Rigid` exists because a policy written elsewhere may specify no
jitter, and comparing against it needs the undelayed value, which `Backoff::ceiling`
gives.

## A note on the newest-first order

A pool hands out the most recently returned resource, not the oldest. A warm
connection is likelier to still be good, and handing out the newest lets the oldest
age past `keep` and be evicted — which is how a pool shrinks again after a burst.
A queue would keep every connection just warm enough never to be collected.

## One package, not three

The plan for this repository had `pool`, `retry` and `flow` as separate packages.
They are one, because splitting a package is worth doing when it lets a caller carry
one dependency fewer, and none of the three brings a dependency the others do not.
Splitting for tidiness is a ceremony; `moonlog` made the same call for the same
reason.

## Install

```bash
moon add moonbitstack/moonpool
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
