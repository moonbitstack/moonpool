// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "the books say what the pool holds and what it did" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  assert_eq(p.give(1, ms(1L)), true)
  // One reused from idle, and one made for the asker: the cold start is the part
  // of `loans` that `reused` does not account for.
  assert_eq(p.take(ms(2L)) is Ready(1), true)
  let books = p.books()
  assert_eq(books.live, 1)
  assert_eq(books.idle, 0)
  assert_eq(books.busy, 1)
  assert_eq(books.made, 1L)
  assert_eq(books.failed, 0L)
  assert_eq(books.loans, 2L)
  assert_eq(books.reused, 1L)
  assert_eq(books.retired, 0L)
  assert_eq(books.waited, 0L)
  assert_eq(books.shed, 0L)
}

///|
test "every refusal is counted under the answer it gave" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(size=1, keep=@moondate.Span::new(seconds=1L)),
    ward=Ward::new(backoff=@moonward.backoff),
  )
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  // At the size, and then holding a make back after one that failed.
  assert_eq(p.take(0L) is Wait, true)
  p.drop(1)
  p.unmade(0L)
  assert_eq(p.take(ms(1L)) is Later(_), true)
  // A resource handed back and left sitting past `keep`, so the next take has to
  // retire it.
  p.made(2, 0L)
  p.give(2, 0L) |> ignore
  assert_eq(p.take(ms(2_000L)) is Stale(2), true)
  let books = p.books()
  assert_eq(books.waited, 1L)
  assert_eq(books.deferred, 1L)
  assert_eq(books.failed, 1L)
  assert_eq(books.retired, 1L)
  assert_eq(books.made, 2L)
}

///|
test "a shed is counted, and so is one the eviction timer retired" {
  let breaker = @moonward.Breaker::new(sre={ ..@moonward.sre, protection: 0.0, })
  let watched : Pool[Int32] = Pool::new(ward=Ward::new(breaker~))
  assert_eq(watched.take(0L) is Make, true)
  watched.unmade(0L)
  assert_eq(watched.take(0L, roll=0.1) is Shed, true)
  assert_eq(watched.books().shed, 1L)
  let aged : Pool[Int32] = Pool::new(
    limits=Limits::new(size=2, keep=@moondate.Span::new(seconds=1L)),
  )
  assert_eq(aged.take(0L) is Make, true)
  aged.give(1, 0L) |> ignore
  assert_eq(aged.evict(ms(2_000L)), [1])
  assert_eq(aged.books().retired, 1L)
}

///|
test "the books of a pool that has done nothing are all zero" {
  let p : Pool[Int32] = Pool::new()
  assert_eq(p.books(), {
    live: 0,
    idle: 0,
    busy: 0,
    made: 0L,
    failed: 0L,
    loans: 0L,
    reused: 0L,
    retired: 0L,
    waited: 0L,
    deferred: 0L,
    shed: 0L,
  })
}

///|
test "loans answer what is out, and for how long it has been out" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.loans(0L).length(), 0)
  assert_eq(p.take(0L) is Make, true)
  p.made(1, ms(10L))
  assert_eq(p.take(ms(10L)) is Make, true)
  p.made(2, ms(20L))
  // One lent at ten milliseconds, one at twenty: a leak detector compares each
  // span with its own threshold and logs the item it finds.
  let out = p.loans(ms(50L))
  assert_eq(out.length(), 2)
  assert_eq(out[0].item, 1)
  assert_eq(out[0].held, @moondate.Span::new(millis=40L))
  assert_eq(out[1].item, 2)
  assert_eq(out[1].held, @moondate.Span::new(millis=30L))
  // A loan that comes back is no longer out, and neither is one that broke.
  p.give(1, ms(60L)) |> ignore
  p.drop(2)
  assert_eq(p.loans(ms(70L)).length(), 0)
}
