// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How long a `Later` asks the caller to wait; nothing for any other answer.
fn later(taken : Taken[Int32]) -> @moondate.Span? {
  match taken {
    Later(span) => Some(span)
    _ => None
  }
}

///|
test "a breaker stops new connections to a backend that keeps failing" {
  let breaker = @moonward.Breaker::new(sre={ ..@moonward.sre, protection: 0.0, })
  let p : Pool[Int32] = Pool::new(ward=Ward::new(breaker~))
  assert_eq(p.take(0L) is Make, true)
  p.unmade(0L)
  assert_eq(p.refusal(0L) > 0.0, true)
  assert_eq(p.take(0L, roll=0.1) is Shed, true)
  assert_eq(p.take(0L, roll=0.9) is Make, true)
  p.made(7, 0L)
  assert_eq(p.live(), 1)
}

///|
test "a bucket spaces out new connections" {
  let p : Pool[Int32] = Pool::new(
    ward=Ward::new(bucket=@moonward.Bucket::new(1.0, burst=1.0)),
  )
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  assert_eq(later(p.take(0L)), Some(@moondate.Span::new(seconds=1L)))
  assert_eq(p.take(ms(1000L)) is Make, true)
}

///|
test "after a failed connection the pool waits out the backoff" {
  let p : Pool[Int32] = Pool::new(
    ward=Ward::new(
      backoff=@moonward.Backoff::new(
        base=@moondate.Span::new(millis=100L),
        cap=@moondate.Span::new(seconds=5L),
        jitter=Rigid,
      ),
    ),
  )
  assert_eq(p.take(0L) is Make, true)
  p.unmade(0L)
  assert_eq(later(p.take(ms(50L))), Some(@moondate.Span::new(millis=50L)))
  assert_eq(p.take(ms(100L)) is Make, true)
  p.unmade(ms(100L))
  assert_eq(later(p.take(ms(150L))), Some(@moondate.Span::new(millis=150L)))
  assert_eq(p.take(ms(300L)) is Make, true)
  p.made(3, ms(300L))
  p.give(3, ms(300L)) |> ignore
  assert_eq(p.take(ms(300L)) is Ready(3), true)
}

///|
test "a shedder stops lending when the process is hot and full" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(size=0),
    ward=Ward::new(shedder=@moonward.Shedder::new()),
  )
  for i in 0..<5 {
    assert_eq(p.take(0L) is Make, true)
    p.made(i, 0L)
  }
  // Lending and returning one more, forty times over, teaches the shedder that
  // five are usually in flight.
  for i in 0..<40 {
    match p.take(ms(1L)) {
      Ready(item) => p.give(item, ms(2L)) |> ignore
      Make => {
        p.made(100 + i, ms(1L))
        p.give(100 + i, ms(2L)) |> ignore
      }
      _ => abort("refused while the processor was cool")
    }
  }
  assert_eq(p.take(ms(4L), cpu=1000) is Shed, true)
  // Having shed, it stays hot for a second even once the load falls.
  assert_eq(p.take(ms(500L), cpu=100) is Shed, true)
  assert_eq(p.take(ms(1100L), cpu=100) is Ready(_), true)
}

///|
test "without a ward nothing is held back" {
  let p : Pool[Int32] = Pool::new()
  for i in 0..<10 {
    assert_eq(p.take(0L, roll=0.0, cpu=1000) is Make, true)
    p.unmade(0L)
    ignore(i)
  }
  assert_eq(p.take(0L) is Make, true)
}

///|
test "two choices prefer the pool that refuses less, then the idler one" {
  let breaker = @moonward.Breaker::new(sre={ ..@moonward.sre, protection: 0.0, })
  let sick : Pool[Int32] = Pool::new(ward=Ward::new(breaker~))
  ignore(sick.take(0L))
  sick.unmade(0L)
  let well : Pool[Int32] = Pool::new()
  let busy : Pool[Int32] = Pool::new()
  ignore(busy.take(0L))
  let pools = [sick, well, busy]
  assert_eq(pick(pools[:], 0L, first=0.0, second=0.5), 1)
  assert_eq(pick(pools[:], 0L, first=0.9, second=0.5), 1)
  assert_eq(pick(pools[:], 0L, first=0.1, second=0.1), 0)
  assert_eq(pick(pools[0:0], 0L, first=0.1, second=0.2), -1)
}
