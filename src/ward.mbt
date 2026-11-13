// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What stands in front of a pool's backend. Every part is optional and the
/// preset has none, which leaves the pool exactly as it is without a ward.
///
/// The four guards are about a backend that misbehaves. The limiter is about the
/// pool's own concurrency: it holds a lease for every loan, and the limit it keeps
/// moves with how long those loans take, so a quiet backend is allowed more at once
/// and a slow one fewer, under the same `size`.
pub(all) struct Ward {
  breaker : @moonward.Breaker?
  bucket : @moonward.Bucket?
  backoff : @moonward.Backoff?
  shedder : @moonward.Shedder?
  limiter : @moonward.Limiter?
}

///|
pub let ward : Ward = {
  breaker: None,
  bucket: None,
  backoff: None,
  shedder: None,
  limiter: None,
}

///|
pub fn Ward::new(
  breaker? : @moonward.Breaker,
  bucket? : @moonward.Bucket,
  backoff? : @moonward.Backoff,
  shedder? : @moonward.Shedder,
  limiter? : @moonward.Limiter,
) -> Ward {
  { breaker, bucket, backoff, shedder, limiter, }
}

///|
pub using @moonward {
  type Backoff,
  type Bucket,
  type Gate,
  type Jitter,
  type Sliding,
  backoff,
}
