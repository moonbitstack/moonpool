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
///
/// The last two come only from a [`Ward`]: `Later` is making held back for that
/// long, by the bucket or by backoff after a failure; `Shed` is the breaker
/// refusing new connections to a failing backend, or the shedder refusing to lend
/// while the process is overloaded.
pub(all) enum Taken[T] {
  Ready(T)
  Stale(T)
  Make
  Wait
  Later(@moondate.Span)
  Shed
}

///|
/// The limits a pool holds itself to.
///
/// The preset is [`limits`]. Build another with [`Limits::new`], or update one in
/// place with `{ ..limits, size: 32 }`.
pub(all) struct Limits {
  size : Int32
  idle : Int32
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
  size~ : Int32 = limits.size,
  idle~ : Int32 = limits.idle,
  keep~ : @moondate.Span = limits.keep,
  life~ : @moondate.Span = limits.life,
) -> Limits {
  { size, idle, keep, life, }
}

///|
/// What stands in front of a pool's backend. Every part is optional and the
/// preset has none, which leaves the pool exactly as it is without a ward.
pub(all) struct Ward {
  breaker : @moonward.Breaker?
  bucket : @moonward.Bucket?
  backoff : @moonward.Backoff?
  shedder : @moonward.Shedder?
}

///|
pub let ward : Ward = {
  breaker: None,
  bucket: None,
  backoff: None,
  shedder: None,
}

///|
pub fn Ward::new(
  breaker? : @moonward.Breaker,
  bucket? : @moonward.Bucket,
  backoff? : @moonward.Backoff,
  shedder? : @moonward.Shedder,
) -> Ward {
  { breaker, bucket, backoff, shedder, }
}

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
///
/// Idle resources are kept as `(item, born, rested)`, lent ones as `(item, born,
/// ticket)`, and each resource being made as the breaker's promise and the
/// shedder's ticket it will settle.
struct Pool[T] {
  limits : Limits
  ward : Ward
  free : Array[(T, Int64, Int64)]
  out : Array[(T, Int64, @moonward.Ticket?)]
  making : Array[(@moonward.Promise?, @moonward.Ticket?)]
  mut failures : Int32
  mut hold : Int64
}

///|
/// An empty pool.
pub fn[T] Pool::new(limits~ : Limits = limits, ward~ : Ward = ward) -> Pool[T] {
  { limits, ward, free: [], out: [], making: [], failures: 0, hold: 0L, }
}

///|
/// How many resources exist right now: idle, lent, and being made.
pub fn[T] Pool::live(self : Pool[T]) -> Int32 {
  self.free.length() + self.out.length() + self.making.length()
}

///|
/// How many are sitting idle.
pub fn[T] Pool::idle(self : Pool[T]) -> Int32 {
  self.free.length()
}

///|
/// How many are lent out or being made.
pub fn[T] Pool::busy(self : Pool[T]) -> Int32 {
  self.out.length() + self.making.length()
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
pub fn[T] Pool::take(
  self : Pool[T],
  now : Int64,
  roll~ : Double = 0.5,
  cpu~ : Int32 = 0,
) -> Taken[T] {
  if self.free.last() is Some(held) && self.expired(held.1, held.2, now) {
    self.free.pop() |> ignore
    return Stale(held.0)
  }
  let ticket = match self.ward.shedder {
    Some(shedder) =>
      match shedder.allow(now, cpu) {
        Some(ticket) => Some(ticket)
        None => return Shed
      }
    None => None
  }
  if self.free.pop() is Some(held) {
    self.out.push((held.0, held.1, ticket))
    return Ready(held.0)
  }
  let refuse = (taken : Taken[T]) => {
    if ticket is Some(t) {
      t.fail()
    }
    taken
  }
  if self.limits.size > 0 && self.live() >= self.limits.size {
    return refuse(Wait)
  }
  if now < self.hold {
    return refuse(Later({ nanos: self.hold - now, }))
  }
  if self.ward.bucket is Some(bucket) && !bucket.take(now) {
    return refuse(Later(bucket.next(now)))
  }
  let promise = match self.ward.breaker {
    Some(breaker) =>
      match breaker.allow(now, roll) {
        Some(promise) => Some(promise)
        None => return refuse(Shed)
      }
    None => None
  }
  self.making.push((promise, ticket))
  Make
}

///|
/// Register a resource made after `take` said `Make`, as lent and born `now`.
pub fn[T] Pool::made(self : Pool[T], item : T, now : Int64) -> Unit {
  let (promise, ticket) = self.reservation()
  if promise is Some(p) {
    p.pass(now)
  }
  self.failures = 0
  self.hold = 0L
  self.out.push((item, now, ticket))
}

///|
/// Give back a reservation that did not become a resource: the attempt to make
/// it failed. The breaker counts the failure, and with a `Backoff` in the ward
/// no `Make` is handed out again until its delay has passed; `roll` draws the
/// jitter.
pub fn[T] Pool::unmade(
  self : Pool[T],
  now : Int64,
  roll~ : Double = 0.5,
) -> Unit {
  let (promise, ticket) = self.reservation()
  if promise is Some(p) {
    p.fail(now)
  }
  if ticket is Some(t) {
    t.fail()
  }
  self.failures += 1
  if self.ward.backoff is Some(backoff) {
    self.hold = now + backoff.delay(self.failures, random=roll).nanos
  }
}

///|
/// The oldest reservation, or nothing to settle when there is none.
fn[T] Pool::reservation(
  self : Pool[T],
) -> (@moonward.Promise?, @moonward.Ticket?) {
  if self.making.length() == 0 {
    (None, None)
  } else {
    self.making.remove(0)
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
  let (born, ticket) = self.recall(item, now)
  if ticket is Some(t) {
    t.pass(now)
  }
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
  if self.recall(item, 0L).1 is Some(t) {
    t.fail()
  }
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
fn[T] Pool::recall(
  self : Pool[T],
  item : T,
  fallback : Int64,
) -> (Int64, @moonward.Ticket?) {
  for i, lent in self.out {
    if physical_equal(lent.0, item) {
      self.out.remove(i) |> ignore
      return (lent.1, lent.2)
    }
  }
  (fallback, self.reservation().1)
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
