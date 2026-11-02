// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which of several pools to one service to take from: two drawn by `first`
/// and `second`, each in `[0, 1)`, and of those the one whose breaker refuses
/// less, then the one with fewer in use.
///
/// Two random choices spread load almost as evenly as scanning every pool, and
/// cost two draws instead of a walk over all of them. `-1` when there are no pools.
pub fn[T] pick(
  pools : ArrayView[Pool[T]],
  now : Int64,
  first~ : Double,
  second~ : Double,
) -> Int32 {
  let count = pools.length()
  if count == 0 {
    return -1
  }
  let a = slot(first, count)
  let b = slot(second, count)
  let (ra, rb) = (pools[a].refusal(now), pools[b].refusal(now))
  if ra != rb {
    return if ra < rb { a } else { b }
  }
  if pools[b].busy() < pools[a].busy() {
    b
  } else {
    a
  }
}

///|
/// The share of new connections the ward's breaker is refusing at `now`; zero
/// without a breaker.
pub fn[T] Pool::refusal(self : Pool[T], now : Int64) -> Double {
  match self.ward.breaker {
    Some(breaker) => breaker.ratio(now)
    None => 0.0
  }
}

///|
fn slot(draw : Double, count : Int32) -> Int32 {
  let at = (draw * count.to_double()).to_int()
  if at < 0 {
    0
  } else if at >= count {
    count - 1
  } else {
    at
  }
}

///|
/// Takes turns. It holds only a cursor, so it costs nothing to keep one per client.
pub struct RoundRobin {
  priv mut cursor : Int32
}

///|
/// A rotation starting at the first target.
pub fn RoundRobin::new() -> RoundRobin {
  { cursor: 0, }
}

///|
/// The next of `count` targets, or `-1` when there are none. The cursor wraps at the current
/// count, so it stays valid as targets come and go.
pub fn RoundRobin::pick(self : RoundRobin, count : Int32) -> Int32 {
  if count <= 0 {
    return -1
  }
  let at = self.cursor % count
  self.cursor = (at + 1) % count
  at
}

///|
/// Smooth weighted round-robin, nginx's: every pick credits each target with its weight, serves
/// the one with the most credit, and charges it the total. Over a cycle each target gets its
/// share, and the turns interleave: a weight of 5 is not five requests back to back.
///
/// Credit is kept by name, so the list can change order between picks. A target that leaves
/// loses its credit, which was earned under weights that may no longer hold.
pub struct Weighted {
  priv scores : Map[String, Int32]
}

///|
/// A balancer with no credit yet.
pub fn Weighted::new() -> Weighted {
  { scores: Map([]), }
}

///|
/// The index of the next of `targets`, each a name and a weight. A weight of zero or less is
/// never picked, and `-1` means nothing can be.
pub fn Weighted::pick(
  self : Weighted,
  targets : ArrayView[(String, Int32)],
) -> Int32 {
  let mut best = -1
  let mut best_score = 0
  let mut total = 0
  let live : Map[String, Bool] = Map([])
  for at, target in targets {
    let (name, weight) = target
    if weight <= 0 {
      continue
    }
    live[name] = true
    total += weight
    let score = self.scores.get(name).unwrap_or(0) + weight
    self.scores[name] = score
    if best < 0 || score > best_score {
      best = at
      best_score = score
    }
  }
  for name in self.scores.keys().to_array() {
    if !live.contains(name) {
      self.scores.remove(name)
    }
  }
  if best >= 0 {
    self.scores[targets[best].0] = best_score - total
  }
  best
}
