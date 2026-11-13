// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a pool has done, as one reading: how much it holds now, and how much has
/// passed through it.
///
/// The three gauges are the pool at this instant. The counters only ever rise, so
/// the difference between two readings is what happened in between; a service that
/// exports them to its metrics endpoint gets the same numbers a connection pool's
/// management bean would offer.
///
/// `loans` is the total of resources handed to callers, and `reused` the part of it
/// taken from idle — so `loans - reused` is how many were made for the asker, which
/// is the pool's cold-start cost.
#derive(Eq, Debug)
pub(all) struct Books {
  live : Int32
  idle : Int32
  busy : Int32
  made : Int64
  failed : Int64
  loans : Int64
  reused : Int64
  retired : Int64
  waited : Int64
  deferred : Int64
  shed : Int64
}

///|
pub extend Books with Debug::{to_repr}

///|
pub extend Books with Eq::{not_equal, equal}

///|
/// A resource that is out on loan: what it is, and how long it has been gone.
///
/// A caller compares `held` with its own threshold to find a loan that was never
/// given back — what a leak detector logs, with the item so the borrower can be
/// traced.
#derive(Debug)
pub(all) struct Lent[T] {
  item : T
  held : @moondate.Span
}

///|
pub extend Lent with Debug::{to_repr}
