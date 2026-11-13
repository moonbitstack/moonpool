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
/// while the process is overloaded. A ward's limiter can answer `Wait` as well, when
/// the concurrency it allows is already out on loan.
pub(all) enum Taken[T] {
  Ready(T)
  Stale(T)
  Make
  Wait
  Later(@moondate.Span)
  Shed
}

///|
/// An idle resource: what it is, when it was made, and when it last came back.
priv struct Resting[T] {
  item : T
  born : Int64
  rested : Int64
}

///|
/// A resource out on loan: its birth survives the loan, `since` is when this loan
/// began, and the ward's promise and lease are settled when it comes back.
priv struct Loan[T] {
  item : T
  born : Int64
  since : Int64
  ticket : @moonward.Ticket?
  lease : @moonward.Lease?
}

///|
/// A `Make` that has not ended yet: the room it reserved, and what the ward holds
/// until it is settled.
priv struct Reserved {
  promise : @moonward.Promise?
  ticket : @moonward.Ticket?
  lease : @moonward.Lease?
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
struct Pool[T] {
  limits : Limits
  ward : Ward
  free : Array[Resting[T]]
  out : Array[Loan[T]]
  making : Array[Reserved]
  mut made : Int64
  mut failed : Int64
  mut loans : Int64
  mut reused : Int64
  mut retired : Int64
  mut waited : Int64
  mut deferred : Int64
  mut shed : Int64
  mut failures : Int32
  mut hold : Int64
}

///|
/// An empty pool.
pub fn[T] Pool::new(limits~ : Limits = limits, ward~ : Ward = ward) -> Pool[T] {
  {
    limits,
    ward,
    free: [],
    out: [],
    making: [],
    made: 0L,
    failed: 0L,
    loans: 0L,
    reused: 0L,
    retired: 0L,
    waited: 0L,
    deferred: 0L,
    shed: 0L,
    failures: 0,
    hold: 0L,
  }
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
/// The gauges and counters together, as one reading.
pub fn[T] Pool::books(self : Pool[T]) -> Books {
  {
    live: self.live(),
    idle: self.idle(),
    busy: self.busy(),
    made: self.made,
    failed: self.failed,
    loans: self.loans,
    reused: self.reused,
    retired: self.retired,
    waited: self.waited,
    deferred: self.deferred,
    shed: self.shed,
  }
}

///|
/// Every resource that is out on loan, with how long it has been out.
///
/// A pool cannot know which loan was forgotten: only the caller knows how long its
/// own work may take. So the pool tells the truth and the caller sets the
/// threshold — anything held longer than that is a leak to log against the item.
pub fn[T] Pool::loans(self : Pool[T], now : Int64) -> Array[Lent[T]] {
  let out : Array[Lent[T]] = []
  for loan in self.out {
    out.push({ item: loan.item, held: { nanos: now - loan.since, }, })
  }
  out
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
  if self.free.last() is Some(rested) &&
    self.expired(rested.born, rested.rested, now) {
    self.free.pop() |> ignore
    self.retired += 1
    return Stale(rested.item)
  }
  let ticket = match self.ward.shedder {
    Some(shedder) =>
      match shedder.allow(now, cpu) {
        Some(ticket) => Some(ticket)
        None => {
          self.shed += 1
          return Shed
        }
      }
    None => None
  }
  let lease = match self.ward.limiter {
    Some(limiter) =>
      match limiter.acquire(now) {
        Some(lease) => Some(lease)
        None => {
          if ticket is Some(t) {
            t.fail()
          }
          self.waited += 1
          return Wait
        }
      }
    None => None
  }
  if self.free.pop() is Some(rested) {
    self.out.push({
      item: rested.item,
      born: rested.born,
      since: now,
      ticket,
      lease,
    })
    self.loans += 1
    self.reused += 1
    return Ready(rested.item)
  }
  let refuse = (taken : Taken[T]) => {
    if ticket is Some(t) {
      t.fail()
    }
    if lease is Some(l) {
      l.ignore()
    }
    taken
  }
  if self.limits.size > 0 && self.live() >= self.limits.size {
    self.waited += 1
    return refuse(Wait)
  }
  if now < self.hold {
    self.deferred += 1
    return refuse(Later({ nanos: self.hold - now, }))
  }
  if self.ward.bucket is Some(bucket) && !bucket.take(now) {
    self.deferred += 1
    return refuse(Later(bucket.next(now)))
  }
  let promise = match self.ward.breaker {
    Some(breaker) =>
      match breaker.allow(now, roll) {
        Some(promise) => Some(promise)
        None => {
          self.shed += 1
          return refuse(Shed)
        }
      }
    None => None
  }
  self.making.push({ promise, ticket, lease, })
  Make
}

///|
/// Register a resource made after `take` said `Make`, as lent and born `now`.
///
/// A handle the pool already holds is not loaned twice: the registration counts, the
/// reservation it came with is settled, and the loan the pool already had stands. One
/// handle lent twice would be two loans to close with one `give`, which is a slot lost
/// for good.
pub fn[T] Pool::made(self : Pool[T], item : T, now : Int64) -> Unit {
  let reserved = self.reservation()
  if reserved.promise is Some(p) {
    p.pass(now)
  }
  self.made += 1
  self.failures = 0
  self.hold = 0L
  if self.holds(item) {
    if reserved.ticket is Some(t) {
      t.pass(now)
    }
    if reserved.lease is Some(l) {
      l.ignore()
    }
    return
  }
  self.loans += 1
  self.out.push({
    item,
    born: now,
    since: now,
    ticket: reserved.ticket,
    lease: reserved.lease,
  })
}

///|
/// Give back a reservation that did not become a resource: the attempt to make
/// it failed. The breaker counts the failure, and with a `Backoff` in the ward
/// no `Make` is handed out again until its delay has passed; `roll` draws the
/// jitter.
///
/// The limiter that let the attempt through is released without a sample: the
/// breaker is what owns a backend that will not connect, and counting the same
/// failure in two places would shrink the pool twice for one cause.
pub fn[T] Pool::unmade(
  self : Pool[T],
  now : Int64,
  roll~ : Double = 0.5,
) -> Unit {
  let reserved = self.reservation()
  if reserved.promise is Some(p) {
    p.fail(now)
  }
  if reserved.ticket is Some(t) {
    t.fail()
  }
  if reserved.lease is Some(l) {
    l.ignore()
  }
  self.failed += 1
  self.failures += 1
  if self.ward.backoff is Some(backoff) {
    self.hold = now + backoff.delay(self.failures, random=roll).nanos
  }
}

///|
/// The oldest reservation and what the ward holds for it, or nothing at all
/// when there is none.
fn[T] Pool::reservation(self : Pool[T]) -> Reserved {
  if self.making.length() == 0 {
    { promise: None, ticket: None, lease: None, }
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
///
/// One the pool is already holding idle answers `false` as well: a resource handed
/// back twice would otherwise sit in two seats, and a later `take` would lend the same
/// handle to two callers.
pub fn[T] Pool::give(self : Pool[T], item : T, now : Int64) -> Bool {
  if self.resting(item) {
    return false
  }
  let loan = self.recall(item, now)
  if loan.ticket is Some(t) {
    t.pass(now)
  }
  if loan.lease is Some(l) {
    l.pass(now)
  }
  if self.limits.idle > 0 && self.free.length() >= self.limits.idle {
    return false
  }
  self.free.push({ item, born: loan.born, rested: now, })
  true
}

///|
/// Say a lent resource is not coming back, because it broke.
///
/// This is what keeps the live count honest: without it a failed connection would
/// hold a slot for ever and the pool would stop making new ones.
pub fn[T] Pool::drop(self : Pool[T], item : T) -> Unit {
  let loan = self.recall(item, 0L)
  if loan.ticket is Some(t) {
    t.fail()
  }
  if loan.lease is Some(l) {
    l.ignore()
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
  let keep : Array[Resting[T]] = []
  for rested in self.free {
    if self.expired(rested.born, rested.rested, now) {
      gone.push(rested.item)
    } else {
      keep.push(rested)
    }
  }
  self.free.clear()
  for rested in keep {
    self.free.push(rested)
  }
  self.retired += gone.length().to_int64()
  gone
}

///|
/// Everything the pool holds idle, emptied out for the caller to close — what a
/// shutdown does. Lent resources are the borrowers' to return; each comes back
/// through `give` and can be closed then.
pub fn[T] Pool::close(self : Pool[T]) -> Array[T] {
  let out : Array[T] = []
  for rested in self.free {
    out.push(rested.item)
  }
  self.free.clear()
  out
}

///|
/// Take a lent resource off the books, answering the loan it was lent with.
///
/// One the pool never lent answers `fallback` for its birth, and takes over the
/// oldest reservation if there is one: it is the resource a `Make` asked for,
/// coming back without having been registered.
fn[T] Pool::recall(self : Pool[T], item : T, fallback : Int64) -> Loan[T] {
  for i, lent in self.out {
    if physical_equal(lent.item, item) {
      self.out.remove(i) |> ignore
      return lent
    }
  }
  let reserved = self.reservation()
  {
    item,
    born: fallback,
    since: fallback,
    ticket: reserved.ticket,
    lease: reserved.lease,
  }
}

///|
/// Whether this very resource is already sitting idle.
fn[T] Pool::resting(self : Pool[T], item : T) -> Bool {
  for rested in self.free {
    if physical_equal(rested.item, item) {
      return true
    }
  }
  false
}

///|
/// Whether the pool already holds this very resource, idle or lent.
fn[T] Pool::holds(self : Pool[T], item : T) -> Bool {
  if self.resting(item) {
    return true
  }
  for loan in self.out {
    if physical_equal(loan.item, item) {
      return true
    }
  }
  false
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
