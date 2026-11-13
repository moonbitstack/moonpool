// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The limits a pool holds itself to.
///
/// The preset is [`limits`]. Build another with [`Limits::new`], or update one in
/// place with `{ ..limits, size: 32 }`.
///
/// Zero means no ceiling, for `size`, for `idle` and for both ages. A caller that
/// wants nothing kept idle closes what it borrowed instead of giving it back.
#derive(Eq, Debug)
pub(all) struct Limits {
  size : Int32
  idle : Int32
  keep : @moondate.Span
  life : @moondate.Span
}

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
/// Ten live is what most services settle on, and thirty minutes is long enough that
/// a warm pool survives a quiet spell. Keeping `idle` equal to `size` means a pool
/// that grew under load does not immediately throw away what it just made.
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
