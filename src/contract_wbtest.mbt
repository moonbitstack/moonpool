// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// xorshift32, so a walk is the same on every target and every run: a failure is
/// reproducible from the seed alone, with no dependency of its own.
priv struct Dice {
  mut state : UInt32
}

///|
fn Dice::new(seed : UInt32) -> Dice {
  { state: seed, }
}

///|
fn Dice::roll(self : Dice) -> UInt32 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.state = x
  x
}

///|
fn Dice::below(self : Dice, bound : Int32) -> Int32 {
  (self.roll() % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
test "a resource handed back twice is kept once" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  assert_eq(p.give(1, 0L), true)
  // Two seats for one handle would let a later take lend it to two callers.
  assert_eq(p.give(1, 0L), false)
  assert_eq(p.idle(), 1)
  assert_eq(p.live(), 1)
}

///|
test "a resource registered twice keeps one loan" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  assert_eq(p.take(0L) is Make, true)
  // The same handle cannot be out twice: one `give` could not close two loans, and the
  // room the second `Make` reserved would be lost for good.
  p.made(1, 0L)
  assert_eq(p.live(), 1)
  assert_eq(p.busy(), 1)
  assert_eq(p.books().loans, 1L)
  assert_eq(p.books().made, 2L)
  assert_eq(p.give(1, 0L), true)
  assert_eq(p.idle(), 1)
}

///|
test "a resource the pool never lent is taken as born now" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(
      size=2,
      keep=forever,
      life=@moondate.Span::new(seconds=1L),
    ),
  )
  assert_eq(p.give(9, ms(5_000L)), true)
  assert_eq(p.idle(), 1)
  // Born when it arrived, so the lifetime it is held to starts there.
  assert_eq(p.take(ms(5_500L)) is Ready(9), true)
  assert_eq(p.give(9, ms(5_500L)), true)
  assert_eq(p.take(ms(6_500L)) is Stale(9), true)
}

///|
test "a make with no take still registers, and is lent" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  p.made(4, ms(1L))
  assert_eq(p.live(), 1)
  assert_eq(p.busy(), 1)
  assert_eq(p.give(4, ms(2L)), true)
  assert_eq(p.take(ms(3L)) is Ready(4), true)
}

///|
test "an unmade with no take is counted and holds the next make back" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(size=2),
    ward=Ward::new(backoff=@moonward.backoff),
  )
  p.unmade(0L)
  assert_eq(p.live(), 0)
  assert_eq(p.books().failed, 1L)
  assert_eq(p.take(ms(1L)) is Later(_), true)
}

///|
test "dropping something the pool never lent changes nothing" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=2))
  p.drop(9)
  assert_eq(p.live(), 0)
  assert_eq(p.books().loans, 0L)
  assert_eq(p.take(0L) is Make, true)
}

///|
test "a clock that goes backwards never expires anything" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(size=2, keep=@moondate.Span::new(seconds=1L)),
  )
  assert_eq(p.take(ms(5_000L)) is Make, true)
  assert_eq(p.give(1, ms(5_000L)), true)
  assert_eq(p.take(0L) is Ready(1), true)
}

///|
test "zero is no ceiling, for the idle count as for the ages" {
  let open : Pool[Int32] = Pool::new(limits=Limits::new(size=0, idle=0))
  for i in 0..<50 {
    assert_eq(open.take(0L) is Make, true)
    open.made(i, 0L)
  }
  assert_eq(open.live(), 50)
  // A pool that should keep nothing is one whose caller closes instead of giving back;
  // zero here means the ceiling is off, as it does for the two ages.
  assert_eq(open.give(0, 0L), true)
  assert_eq(open.idle(), 1)
  assert_eq(open.live(), 50)
}

///|
test "closing leaves the loans to their borrowers" {
  let p : Pool[Int32] = Pool::new(limits=Limits::new(size=3))
  assert_eq(p.take(0L) is Make, true)
  p.made(1, 0L)
  assert_eq(p.take(0L) is Make, true)
  p.made(2, 0L)
  assert_eq(p.give(2, 0L), true)
  assert_eq(p.close(), [2])
  assert_eq(p.idle(), 0)
  // The one still out comes back to a pool that will not keep it: nothing sits idle.
  assert_eq(p.give(1, 0L), true)
  assert_eq(p.live(), 1)
}

///|
test "the books, the gauges and the loans agree at every step of a random walk" {
  let p : Pool[Int32] = Pool::new(
    limits=Limits::new(
      size=3,
      idle=3,
      keep=@moondate.Span::new(millis=200L),
      life=@moondate.Span::new(seconds=5L),
    ),
  )
  let dice = Dice::new(20_261_114)
  let out : Array[Int32] = []
  let mut next = 0
  let mut now = 0L
  let mut before = p.books()
  for step in 0..<400 {
    now += dice.below(120).to_int64() * 1_000_000L
    match dice.below(10) {
      0 | 1 | 2 | 3 =>
        if out.length() < 3 {
          match p.take(now, roll=dice.below(100).to_double() / 100.0) {
            Make => {
              next += 1
              p.made(next, now)
              out.push(next)
            }
            Ready(item) => out.push(item)
            // A stale one is closed here and not asked for again; the next step takes.
            Stale(_) => ()
            Wait | Later(_) | Shed =>
              abort("a pool this walk never fills cannot refuse")
          }
        }
      4 | 5 | 6 =>
        if out.length() > 0 {
          let at = dice.below(out.length())
          let item = out.remove(at)
          if !p.give(item, now) {
            // kept nothing: the caller closes it, and the pool is one seat lighter
          }
        }
      7 =>
        if out.length() > 0 {
          let at = dice.below(out.length())
          p.drop(out.remove(at))
        }
      8 =>
        for gone in p.evict(now) {
          // The eviction timer hands expired idle ones back; the caller closes them.
          ignore(gone)
        }
      _ => ignore(step)
    }

    let books = p.books()
    assert_eq(books.live, p.live())
    assert_eq(books.idle, p.idle())
    assert_eq(books.busy, p.busy())
    assert_eq(p.live(), p.idle() + p.busy())
    assert_eq(out.length(), p.busy())
    assert_eq(p.loans(now).length(), p.busy())
    // The walk never leaves a `Make` unanswered, so every loan was either made for its
    // asker or reused from idle.
    assert_eq(books.loans, books.made + books.reused)
    assert_eq(p.live() <= 3, true)
    if books.made < before.made ||
      books.failed < before.failed ||
      books.loans < before.loans ||
      books.reused < before.reused ||
      books.retired < before.retired ||
      books.waited < before.waited ||
      books.deferred < before.deferred ||
      books.shed < before.shed {
      abort("a counter went down")
    }
    before = books
  }
  // The walk is only worth its name if it went through the paths that matter: makes,
  // reuses and retirements, not four hundred no-ops.
  let walked = p.books()
  assert_eq(walked.made > 20, true)
  assert_eq(walked.reused > 20, true)
  assert_eq(walked.retired > 0, true)
  assert_eq(walked.loans > 50, true)
  // Whatever is idle at the end is handed to the caller to close, and nothing else.
  let closed = p.close()
  assert_eq(closed.length(), p.idle())
  assert_eq(p.loans(now).length(), out.length())
}
