// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Nanoseconds, for a test that drives a clock by hand.
fn ms(n : Int64) -> Int64 {
  n * 1_000_000L
}

///|
test "an empty pool says to make one, until the size is reached" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.take(0L) is Make, true)
  assert_eq(p.take(0L) is Make, true)
  // Two are out and the size is two, so there is nothing to do but wait.
  assert_eq(p.take(0L) is Wait, true)
  assert_eq(p.live(), 2)
  assert_eq(p.busy(), 2)
  assert_eq(p.idle(), 0)
}

///|
test "a returned resource is handed out again" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=2))
  let _ = p.take(0L)
  assert_eq(p.give(7, ms(1L)), true)
  assert_eq(p.idle(), 1)
  assert_eq(p.busy(), 0)
  match p.take(ms(2L)) {
    Ready(v) => assert_eq(v, 7)
    _ => fail("an idle resource should be handed out")
  }
  assert_eq(p.idle(), 0)
  assert_eq(p.busy(), 1)
}

///|
test "the newest is handed out first, so the oldest can age out" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=4))
  // All three are checked out first; giving one back while another is out is what
  // a pool under load actually does.
  for i = 0; i < 3; i = i + 1 {
    let _ = p.take(0L)
  }
  for v in [1, 2, 3] {
    let _ = p.give(v, ms(v.to_int64()))
  }
  let got : Array[Int] = []
  for i = 0; i < 3; i = i + 1 {
    match p.take(ms(10L)) {
      Ready(v) => got.push(v)
      _ => fail("three were returned")
    }
  }
  assert_eq(got, [3, 2, 1])
}

///|
test "a pool full of idle resources refuses to keep another" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=4, idle=2))
  for i = 0; i < 3; i = i + 1 {
    let _ = p.take(0L)
  }
  assert_eq(p.give(1, 0L), true)
  assert_eq(p.give(2, 0L), true)
  // The third has nowhere to sit, so the caller is told to close it.
  assert_eq(p.give(3, 0L), false)
  assert_eq(p.idle(), 2)
  assert_eq(p.live(), 2)
}

///|
test "a broken resource frees its slot rather than holding it for ever" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=1))
  assert_eq(p.take(0L) is Make, true)
  assert_eq(p.take(0L) is Wait, true)
  // Without this the pool would think one is still out and never make another.
  p.drop(1)
  assert_eq(p.live(), 0)
  assert_eq(p.take(0L) is Make, true)
}

///|
test "a resource that has sat too long is evicted" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(size=4, keep=@moondate.Span::new(seconds=30L)),
  )
  let _ = p.take(0L)
  let _ = p.give(1, 0L)
  // Not yet.
  assert_eq(p.evict(ms(29_000L)).length(), 0)
  assert_eq(p.idle(), 1)
  // And now.
  assert_eq(p.evict(ms(30_000L)), [1])
  assert_eq(p.idle(), 0)
  assert_eq(p.live(), 0)
}

///|
test "a resource that has lived too long is evicted however recently it was used" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(
      size=4,
      keep=@moondate.Span::new(minutes=30L),
      life=@moondate.Span::new(seconds=10L),
    ),
  )
  let _ = p.take(0L)
  p.made(1, 0L)
  // Born at zero, handed back at nine seconds: young by idle time, old by age.
  let _ = p.give(1, ms(9_000L))
  assert_eq(p.evict(ms(9_500L)).length(), 0)
  assert_eq(p.evict(ms(10_000L)), [1])
}

///|
test "an expired resource is not handed out, even before eviction runs" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(size=4, keep=@moondate.Span::new(seconds=1L)),
  )
  let _ = p.take(0L)
  let _ = p.give(1, 0L)
  // The timer has not run, but taking one must not hand back a stale resource as
  // ready. It comes back as stale, for the caller to close, and is off the books.
  match p.take(ms(2_000L)) {
    Stale(v) => assert_eq(v, 1)
    _ => fail("an expired resource should come back stale")
  }
  assert_eq(p.idle(), 0)
  assert_eq(p.live(), 0)
  assert_eq(p.take(ms(2_000L)) is Make, true)
}

///|
test "no stale resource is lost: every one taken out is handed to the caller" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(size=4, keep=@moondate.Span::new(seconds=1L)),
  )
  for i = 0; i < 3; i = i + 1 {
    let _ = p.take(0L)
  }
  for v in [1, 2, 3] {
    let _ = p.give(v, 0L)
  }
  // 0.1.0 skipped past these to answer `Make`, and the three were never closed.
  let closed : Array[Int] = []
  for ;; {
    match p.take(ms(5_000L)) {
      Stale(v) => closed.push(v)
      Make => break
      _ => fail("only stale resources and room to make one are left")
    }
  }
  assert_eq(closed, [3, 2, 1])
}

///|
test "birth survives a loan, so a reused resource still retires by age" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(
      size=4,
      keep=@moondate.Span::new(minutes=30L),
      life=@moondate.Span::new(seconds=10L),
    ),
  )
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  // Lent and returned twice, the last time a second before its tenth birthday.
  let _ = p.give(1, ms(1_000L))
  assert_eq(p.take(ms(2_000L)) is Ready(1), true)
  let _ = p.give(1, ms(9_000L))
  // 0.1.0 stamped it born again at nine seconds and kept it until nineteen.
  assert_eq(p.evict(ms(10_000L)), [1])
}

///|
test "a registered resource is counted as lent until it comes back" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.take(0L) is Make, true)
  p.made(5, 0L)
  assert_eq(p.live(), 1)
  assert_eq(p.busy(), 1)
  p.drop(5)
  assert_eq(p.live(), 0)
  assert_eq(p.busy(), 0)
}

///|
test "a resource that could not be made gives its room back" {
  let p : Pool[Int] = Pool::new(limits=Limits::new(size=1))
  assert_eq(p.take(0L) is Make, true)
  assert_eq(p.take(0L) is Wait, true)
  p.unmade()
  assert_eq(p.live(), 0)
  assert_eq(p.take(0L) is Make, true)
}

///|
test "zero means no limit, for the size and for both ages" {
  let p : Pool[Int] = Pool::new(
    limits=Limits::new(size=0, keep=forever, life=forever),
  )
  for i = 0; i < 100; i = i + 1 {
    assert_eq(p.take(0L) is Make, true)
  }
  let _ = p.give(1, 0L)
  // A hundred years later it is still not too old.
  assert_eq(p.evict(ms(3_153_600_000_000L)).length(), 0)
}

///|
test "closing hands everything back for the caller to close" {
  let p : Pool[Int] = Pool::new()
  for i = 0; i < 3; i = i + 1 {
    let _ = p.take(0L)
  }
  for v in [1, 2, 3] {
    let _ = p.give(v, 0L)
  }
  assert_eq(p.close(), [1, 2, 3])
  assert_eq(p.idle(), 0)
}

///|
test "the preset is the one every connection pool in reach uses" {
  assert_eq(limits.size, 10)
  assert_eq(limits.idle, 10)
  assert_eq(limits.keep, @moondate.Span::new(minutes=30L))
  assert_eq(limits.life, forever)
}
