// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "round robin takes turns and wraps at the current count" {
  let turns = RoundRobin::new()
  assert_eq([turns.pick(3), turns.pick(3), turns.pick(3), turns.pick(3)], [
    0, 1, 2, 0,
  ])
  assert_eq(turns.pick(1), 0)
  assert_eq(turns.pick(0), -1)
}

///|
test "weighted gives each target its share, interleaved" {
  let weighted = Weighted::new()
  let targets = [("a", 5), ("b", 1), ("c", 1)]
  let seen = Array::makei(7, _ => weighted.pick(targets))
  assert_eq(seen, [0, 0, 1, 0, 2, 0, 0])
  assert_eq(seen.filter(at => at == 0).length(), 5)
}

///|
test "weighted never picks a weight of zero, and may pick nothing" {
  let weighted = Weighted::new()
  assert_eq(weighted.pick([("a", 0), ("b", 2)]), 1)
  assert_eq(weighted.pick([("a", 0), ("b", -1)]), -1)
  assert_eq(weighted.pick([]), -1)
}

///|
test "weighted keeps credit by name across reordering" {
  let weighted = Weighted::new()
  let first = weighted.pick([("a", 3), ("b", 1)])
  assert_eq(first, 0)
  // Both now stand at 2, and the tie goes to the one listed first. Credit kept by position would
  // have given the second place 4.
  assert_eq(weighted.pick([("b", 1), ("a", 3)]), 0)
}

///|
test "weighted forgets a target that left" {
  let weighted = Weighted::new()
  ignore(weighted.pick([("a", 1), ("b", 1)]))
  ignore(weighted.pick([("b", 1)]))
  assert_eq(weighted.scores.contains("a"), false)
}
