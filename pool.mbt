// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a pool answers when asked for a resource.
///
/// It never blocks and never opens anything: waiting and connecting both need a
/// runtime, and this package has none. `Make` is the pool saying there is room for
/// another, and reserving it; `Wait` is it saying there is not, and the caller's
/// queue decides what that means. `Stale` is an idle resource too old to use, handed
/// back so the caller can close it before asking again.
pub(all) enum Taken[T] {
  Ready(T)
  Stale(T)
  Make
  Wait
}

///|
/// The limits a pool holds itself to.
///
/// The preset is [`limits`]. Build another with [`Limits::new`], or update one in
/// place with `{ ..limits, size: 32 }`.
pub(all) struct Limits {
  size : Int
  idle : Int
  keep : @moondate.Span
  life : @moondate.Span
} derive(Eq, Debug)

///|
pub extend Limits with Debug::{to_repr}

///|
pub extend Limits with Eq::{not_equal, equal}

///|
/// A span meaning "no limit", which is what zero is taken to mean for the two
/// ages: a resource with no maximum age is never too old.
pub let forever : @moondate.Span = @moondate.Span::new()

///|
/// The preset: ten live at once, ten of them allowed to sit idle, discarded after
/// thirty minutes idle and never by age.
///
/// Ten is HikariCP's and `database/sql`'s default pool size, and thirty minutes is
/// `database/sql`'s `SetConnMaxIdleTime` in the shape most deployments set it.
/// Keeping `idle` equal to `size` is `database/sql`'s behaviour too, so a pool that
/// grew under load does not immediately throw the connections away.
pub let limits : Limits = {
  size: 10,
  idle: 10,
  keep: @moondate.Span::new(minutes=30L),
  life: forever,
}

///|
/// Limits by name, every knob with the preset's value.
pub fn Limits::new(
  size? : Int = limits.size,
  idle? : Int = limits.idle,
  keep? : @moondate.Span = limits.keep,
  life? : @moondate.Span = limits.life,
) -> Limits {
  { size, idle, keep, life, }
}

// One resource the pool holds idle, as `(item, born, rested)`, and one it has lent,
// as `(item, born)`. Tuples rather than named types because a named private one
// cannot appear in a public struct's fields, and these are nobody's business outside
// this file.

///|
/// The bookkeeping of holding a limited number of things.
///
/// It does not open, close, or wait — a caller with a runtime does all three. What
/// it knows is how many are live, which are idle, which are lent and since when
/// each was made, and which have sat or lived long enough to be let go.
///
/// Time is passed in as whatever the caller's clock reads, in nanoseconds; the
/// value's origin does not matter because only differences are used. That is what
/// makes a test drive a pool through an hour in three lines.
///
/// A lent resource is recognised on its way back by identity, which is what every
/// connection handle has. That is how its birth survives the loan: a pool that
/// stamped a returned resource as new would never retire one by age, however old.
pub struct Pool[T] {
  limits : Limits
  free : Array[(T, Int64, Int64)]
  out : Array[(T, Int64)]
  mut reserved : Int
}

///|
/// An empty pool.
pub fn[T] Pool::new(limits? : Limits = limits) -> Pool[T] {
  { limits, free: [], out: [], reserved: 0, }
}

///|
/// How many resources exist right now: idle, lent, and being made.
pub fn[T] Pool::live(self : Pool[T]) -> Int {
  self.free.length() + self.out.length() + self.reserved
}

///|
/// How many are sitting idle.
pub fn[T] Pool::idle(self : Pool[T]) -> Int {
  self.free.length()
}

///|
/// How many are lent out or being made.
pub fn[T] Pool::busy(self : Pool[T]) -> Int {
  self.out.length() + self.reserved
}

///|
/// Take one, or be told to make one, or to wait — or be handed one that is too old
/// to use.
///
/// The most recently returned resource is handed out first. That is not arbitrary:
/// a warm connection is likelier to still be good than a cold one, and handing out
/// the newest lets the oldest age past `keep` and be evicted, which is how a pool
/// shrinks after a burst.
///
/// `Stale` is an idle resource past its age. It is already out of the pool and out
/// of the count; the caller closes it and takes again. Handing it back rather than
/// dropping it is the point — a pool that discarded it silently would leak whatever
/// it holds whenever the eviction timer had not run first.
pub fn[T] Pool::take(self : Pool[T], now : Int64) -> Taken[T] {
  match self.free.pop() {
    Some(held) =>
      if self.expired(held.1, held.2, now) {
        Stale(held.0)
      } else {
        self.out.push((held.0, held.1))
        Ready(held.0)
      }
    None =>
      if self.limits.size <= 0 || self.live() < self.limits.size {
        self.reserved = self.reserved + 1
        Make
      } else {
        Wait
      }
  }
}

///|
/// Register a resource made after `take` said `Make`, as lent and born `now`.
pub fn[T] Pool::made(self : Pool[T], item : T, now : Int64) -> Unit {
  if self.reserved > 0 {
    self.reserved = self.reserved - 1
  }
  self.out.push((item, now))
}

///|
/// Say the resource `take` reserved room for could not be made, so the room is free
/// again. Without it a factory that failed once would shrink the pool for good.
pub fn[T] Pool::unmade(self : Pool[T]) -> Unit {
  if self.reserved > 0 {
    self.reserved = self.reserved - 1
  }
}

///|
/// Hand one back, keeping the birth it was lent with.
///
/// `false` means the pool did not keep it and the caller should close it: there were
/// already enough idle. A resource that is broken goes to [`Pool::drop`] instead,
/// because a pool that kept it would hand it to the next caller.
///
/// A resource the pool does not recognise is one made after a `Make` without
/// [`Pool::made`] being called: it fills the room `take` reserved and is taken as
/// born `now`.
pub fn[T] Pool::give(self : Pool[T], item : T, now : Int64) -> Bool {
  let born = self.recall(item, now)
  if self.limits.idle > 0 && self.free.length() >= self.limits.idle {
    return false
  }
  self.free.push((item, born, now))
  true
}

///|
/// Say a lent resource is not coming back, because it broke.
///
/// This is what keeps the live count honest: without it a failed connection would
/// hold a slot for ever and the pool would stop making new ones.
pub fn[T] Pool::drop(self : Pool[T], item : T) -> Unit {
  let _ = self.recall(item, 0L)
}

///|
/// Every idle resource that has sat longer than `keep` or lived longer than `life`,
/// removed from the pool and handed back for the caller to close.
///
/// Called on a timer by whoever owns the runtime. `take` hands a stale one back too,
/// so a resource is never lost for want of the timer having run.
pub fn[T] Pool::evict(self : Pool[T], now : Int64) -> Array[T] {
  let gone : Array[T] = []
  let keep : Array[(T, Int64, Int64)] = []
  for held in self.free {
    if self.expired(held.1, held.2, now) {
      gone.push(held.0)
    } else {
      keep.push(held)
    }
  }
  self.free.clear()
  for held in keep {
    self.free.push(held)
  }
  gone
}

///|
/// Everything the pool holds idle, emptied out for the caller to close — what a
/// shutdown does. Lent resources are the borrowers' to return; each comes back
/// through `give` and can be closed then.
pub fn[T] Pool::close(self : Pool[T]) -> Array[T] {
  let out : Array[T] = []
  for held in self.free {
    out.push(held.0)
  }
  self.free.clear()
  out
}

///|
/// Take a lent resource off the books, answering the birth it was lent with.
///
/// One the pool never lent answers `fallback` and frees a reserved room, if there is
/// one: it is the resource a `Make` asked for, coming back without having been
/// registered.
fn[T] Pool::recall(self : Pool[T], item : T, fallback : Int64) -> Int64 {
  for i = 0; i < self.out.length(); i = i + 1 {
    if physical_equal(self.out[i].0, item) {
      let born = self.out[i].1
      self.out.remove(i) |> ignore
      return born
    }
  }
  self.unmade()
  fallback
}

///|
/// Whether a resource born at `born` and idle since `rested` is too old to hand out.
fn[T] Pool::expired(
  self : Pool[T],
  born : Int64,
  rested : Int64,
  now : Int64,
) -> Bool {
  if self.limits.keep.nanos > 0L && now - rested >= self.limits.keep.nanos {
    return true
  }
  if self.limits.life.nanos > 0L && now - born >= self.limits.life.nanos {
    return true
  }
  false
}
