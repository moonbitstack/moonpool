// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A token bucket: `rate` tokens accrue per second up to `burst`, and each request
/// takes one.
///
/// It is the rate limiter that allows a burst after a quiet period, which is what
/// a limit on a human-facing API wants — nobody should be refused for making two
/// requests in the same second after an hour of making none.
///
/// Time is nanoseconds from the caller's clock, as everywhere in this package.
pub struct Bucket {
  rate : Double
  burst : Double
  mut tokens : Double
  mut at : Int64
}

///|
/// A bucket that starts full, which is what lets the first burst through.
///
/// `rate` is tokens per second and `burst` is the most it will ever hold. A burst
/// smaller than one means nothing ever passes, so it is raised to one.
pub fn Bucket::new(
  rate : Double,
  burst? : Double = 0.0,
  at? : Int64 = 0L,
) -> Bucket {
  let cap = if burst > 0.0 { burst } else if rate > 1.0 { rate } else { 1.0 }
  { rate, burst: cap, tokens: cap, at, }
}

///|
/// Whether `n` tokens are available now, taking them if they are.
pub fn Bucket::take(self : Bucket, now : Int64, n? : Double = 1.0) -> Bool {
  self.fill(now)
  if self.tokens >= n {
    self.tokens = self.tokens - n
    return true
  }
  false
}

///|
/// How long until `n` tokens would be available, without taking them.
///
/// Zero when they are available now. This is what a caller sleeps for rather than
/// spinning, and what a `Retry-After` header is computed from.
pub fn Bucket::next(
  self : Bucket,
  now : Int64,
  n? : Double = 1.0,
) -> @moondate.Span {
  self.fill(now)
  if self.tokens >= n {
    return @moondate.Span::new()
  }
  if self.rate <= 0.0 {
    // Nothing accrues, so the wait is unbounded; a caller is better told a very
    // long time than a zero it would spin on.
    return @moondate.Span::new(days=365L)
  }
  let short = n - self.tokens
  { nanos: (short / self.rate * 1.0e9).to_int64(), }
}

///|
/// How many tokens are in the bucket, for a caller that reports its own headroom.
pub fn Bucket::tokens(self : Bucket, now : Int64) -> Double {
  self.fill(now)
  self.tokens
}

///|
/// Accrue whatever the elapsed time is worth, up to the burst.
fn Bucket::fill(self : Bucket, now : Int64) -> Unit {
  if now <= self.at {
    return
  }
  let elapsed = (now - self.at).to_double() / 1.0e9
  self.tokens = self.tokens + elapsed * self.rate
  if self.tokens > self.burst {
    self.tokens = self.burst
  }
  self.at = now
}

///|
/// A sliding window counter: at most `allow` events in any `window` long stretch.
///
/// Where a bucket smooths, a window counts. A quota of "a thousand a day" is a
/// window, not a rate, and answering it with a bucket would let a client spend the
/// whole day's allowance in the first minute.
///
/// The stamps of the events in the window are kept, so the count is exact rather
/// than the approximation a two-bucket scheme gives.
pub struct Window {
  allow : Int
  window : @moondate.Span
  stamps : Array[Int64]
}

///|
/// An empty window.
pub fn Window::new(allow : Int, window : @moondate.Span) -> Window {
  { allow, window, stamps: [], }
}

///|
/// Whether an event is within the quota now, counting it if it is.
pub fn Window::take(self : Window, now : Int64) -> Bool {
  self.forget(now)
  if self.stamps.length() < self.allow {
    self.stamps.push(now)
    return true
  }
  false
}

///|
/// How many events remain in the current window.
pub fn Window::left(self : Window, now : Int64) -> Int {
  self.forget(now)
  let used = self.stamps.length()
  if used >= self.allow {
    0
  } else {
    self.allow - used
  }
}

///|
/// When the window will next have room, which is when its oldest event falls out.
pub fn Window::next(self : Window, now : Int64) -> @moondate.Span {
  self.forget(now)
  if self.stamps.length() < self.allow {
    return @moondate.Span::new()
  }
  let oldest = self.stamps[0]
  let free_at = oldest + self.window.nanos
  if free_at <= now {
    @moondate.Span::new()
  } else {
    { nanos: free_at - now, }
  }
}

///|
/// Drop the events that have fallen out of the window.
fn Window::forget(self : Window, now : Int64) -> Unit {
  let cut = now - self.window.nanos
  let keep : Array[Int64] = []
  for stamp in self.stamps {
    if stamp > cut {
      keep.push(stamp)
    }
  }
  self.stamps.clear()
  for stamp in keep {
    self.stamps.push(stamp)
  }
}

///|
/// A count with a ceiling: the concurrency limit a server puts on itself.
///
/// Unlike a rate, this does not depend on time at all — it is how many things are
/// happening at once. A server past its limit answers rather than queues, which is
/// what keeps a queue from becoming the outage.
pub struct Gate {
  limit : Int
  mut held : Int
}

///|
/// A gate that nothing has entered.
pub fn Gate::new(limit : Int) -> Gate {
  { limit, held: 0, }
}

///|
/// Whether there is room, taking it if there is.
pub fn Gate::enter(self : Gate) -> Bool {
  if self.limit > 0 && self.held >= self.limit {
    return false
  }
  self.held = self.held + 1
  true
}

///|
/// Give the room back.
pub fn Gate::leave(self : Gate) -> Unit {
  if self.held > 0 {
    self.held = self.held - 1
  }
}

///|
/// How many are inside.
pub fn Gate::held(self : Gate) -> Int {
  self.held
}
