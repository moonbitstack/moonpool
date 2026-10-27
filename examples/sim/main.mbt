// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The pool, worked by a synthetic client. The engine is in `engine/`, where the
// same code is exported to JavaScript for the documentation site; this is the
// terminal side of it.
//
//     moon run examples/sim

///|
fn main {
  println(
    @engine.table(
      "size=12,idle=12,keep=1,life=0,rate=20,hold=300,ticks=240,seed=7,burst=1",
    ),
  )
}
