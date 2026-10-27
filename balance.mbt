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
