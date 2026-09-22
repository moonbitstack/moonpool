// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a pool answers when asked for a resource.
///
/// It never blocks and never opens anything: waiting and connecting both need a
/// runtime, and this package has none. `Make` is the pool saying there is room for
/// another; `Wait` is it saying there is not, and the caller's queue decides what
/// that means.
pub(all) enum Taken[T] {
  Ready(T)
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

// One resource the pool holds, as `(item, born, rested)`. A tuple rather than a
// named type because a named private one cannot appear in a public struct's
// fields, and this one is nobody's business outside this file.

///|
/// The bookkeeping of holding a limited number of things.
///
/// It does not open, close, or wait — a caller with a runtime does all three. What
/// it knows is how many are live, which are idle, and which have sat or lived long
/// enough to be let go.
///
/// Time is passed in as whatever the caller's clock reads, in nanoseconds; the
/// value's origin does not matter because only differences are used. That is what
/// makes a test drive a pool through an hour in three lines.
pub struct Pool[T] {
  limits : Limits
  free : Array[(T, Int64, Int64)]
  mut busy : Int
}

///|
/// An empty pool.
pub fn[T] Pool::new(limits? : Limits = limits) -> Pool[T] {
  { limits, free: [], busy: 0, }
}

///|
/// How many resources exist right now, idle and in use together.
pub fn[T] Pool::live(self : Pool[T]) -> Int {
  self.free.length() + self.busy
}

///|
/// How many are sitting idle.
pub fn[T] Pool::idle(self : Pool[T]) -> Int {
  self.free.length()
}

///|
/// How many are checked out.
pub fn[T] Pool::busy(self : Pool[T]) -> Int {
  self.busy
}

///|
/// Take one, or be told to make one, or to wait.
///
/// The most recently returned resource is handed out first. That is not
/// arbitrary: a warm connection is likelier to still be good than a cold one, and
/// handing out the newest lets the oldest age past `keep` and be evicted, which is
/// how a pool shrinks after a burst.
pub fn[T] Pool::take(self : Pool[T], now : Int64) -> Taken[T] {
  while self.free.length() > 0 {
    let held = self.free[self.free.length() - 1]
    let _ = self.free.pop()
    if self.expired(held, now) {
      // Too old to hand out. It is gone from the pool; the caller closed it when
      // `evict` handed it over, or will when this one does.
      continue
    }
    self.busy = self.busy + 1
    return Ready(held.0)
  }
  if self.limits.size <= 0 || self.live() < self.limits.size {
    self.busy = self.busy + 1
    return Make
  }
  Wait
}

///|
/// Hand one back.
///
/// `false` means the pool did not keep it and the caller should close it: there
/// were already enough idle. A resource that is broken goes to [`Pool::drop`]
/// instead, because a pool that kept it would hand it to the next caller.
pub fn[T] Pool::give(self : Pool[T], item : T, now : Int64) -> Bool {
  if self.busy > 0 {
    self.busy = self.busy - 1
  }
  if self.limits.idle > 0 && self.free.length() >= self.limits.idle {
    return false
  }
  self.free.push((item, now, now))
  true
}

///|
/// Give one back that has just been made, so its age counts from when it was made
/// rather than from when it was first returned.
pub fn[T] Pool::give_new(
  self : Pool[T],
  item : T,
  born : Int64,
  now : Int64,
) -> Bool {
  if self.busy > 0 {
    self.busy = self.busy - 1
  }
  if self.limits.idle > 0 && self.free.length() >= self.limits.idle {
    return false
  }
  self.free.push((item, born, now))
  true
}

///|
/// Say a checked-out resource is not coming back, because it broke.
///
/// This is what keeps the live count honest: without it a failed connection would
/// hold a slot for ever and the pool would stop making new ones.
pub fn[T] Pool::drop(self : Pool[T]) -> Unit {
  if self.busy > 0 {
    self.busy = self.busy - 1
  }
}

///|
/// Every idle resource that has sat longer than `keep` or lived longer than
/// `life`, removed from the pool and handed back for the caller to close.
///
/// Called on a timer by whoever owns the runtime. The pool does not close anything
/// itself, so this is the only way a resource leaves it other than being taken.
pub fn[T] Pool::evict(self : Pool[T], now : Int64) -> Array[T] {
  let out : Array[T] = []
  let keep : Array[(T, Int64, Int64)] = []
  for held in self.free {
    if self.expired(held, now) {
      out.push(held.0)
    } else {
      keep.push(held)
    }
  }
  self.free.clear()
  for held in keep {
    self.free.push(held)
  }
  out
}

///|
/// Everything the pool holds, emptied out for the caller to close — what a shutdown
/// does.
pub fn[T] Pool::close(self : Pool[T]) -> Array[T] {
  let out : Array[T] = []
  for held in self.free {
    out.push(held.0)
  }
  self.free.clear()
  out
}

///|
/// Whether a held resource is too old to hand out.
fn[T] Pool::expired(
  self : Pool[T],
  held : (T, Int64, Int64),
  now : Int64,
) -> Bool {
  if self.limits.keep.nanos > 0L && now - held.2 >= self.limits.keep.nanos {
    return true
  }
  if self.limits.life.nanos > 0L && now - held.1 >= self.limits.life.nanos {
    return true
  }
  false
}
