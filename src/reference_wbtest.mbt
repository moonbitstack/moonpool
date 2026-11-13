// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One move of a caller: ask, hand back, or give up on a broken resource, at the
/// time the plan says.
priv enum Move {
  Take(Int64)
  Give(Int64, Int32)
  Drop(Int64, Int32)
  Pause(Int64)
}

///|
/// A plan and what a reference pool answered: the id each take was given, and how
/// many were idle and live just after it. `-1` for a take that was made to wait.
priv struct Vector {
  name : String
  limits : Limits
  steps : Array[Move]
  takes : Array[Int32]
  gauges : Array[(Int32, Int32)]
}

///|
/// The counter a caller stamps new resources with, so both sides number them the
/// same way: one, two, three.
priv struct Numbered {
  mut made : Int32
}

///|
/// The caller's loop around `take`: a stale resource is closed and the ask repeats,
/// a make is registered, and anything else means this caller could not be served.
/// That is the whole of what a real client does, and it is what the references do
/// inside their own `connect`.
fn borrow(pool : Pool[Int32], numbered : Numbered, now : Int64) -> Int32 {
  for _ in 0..<8 {
    match pool.take(now) {
      Ready(item) => return item
      Stale(_) => continue
      Make => {
        numbered.made += 1
        pool.made(numbered.made, now)
        return numbered.made
      }
      Wait | Later(_) | Shed => return -1
    }
  }
  -1
}

///|
/// Replay one plan and compare every answer with the reference's, naming the source
/// and the step in the message: a differential report has to say which of the two
/// disagreed.
fn replay(source : String, vector : Vector) -> Unit raise {
  let pool : Pool[Int32] = Pool::new(limits=vector.limits)
  let numbered : Numbered = { made: 0, }
  let given : Array[Int32] = []
  for step in vector.steps {
    match step {
      Take(now) => {
        let ask = "\{source}: \{vector.name}: take \{given.length()}"
        let got = borrow(pool, numbered, now)
        let want = vector.takes[given.length()]
        if got != want {
          fail("\{ask} was given \{got}, the reference \{want}")
        }
        let gauge = vector.gauges[given.length()]
        let state = "idle \{pool.idle()}, live \{pool.live()}"
        if (pool.idle(), pool.live()) != gauge {
          fail("\{ask}: \{state}; the reference \{gauge.0}, \{gauge.1}")
        }
        given.push(got)
      }
      Give(now, of) => ignore(pool.give(given[of], now))
      Drop(_now, of) => pool.drop(given[of])
      Pause(_now) => ()
    }
  }
}

///|
test "the answers match SQLAlchemy's pool, step for step" {
  for vector in sqlalchemy_vectors {
    replay("SQLAlchemy", vector)
  }
}

///|
test "the answers match generic-pool's, step for step" {
  for vector in generic_pool_vectors {
    replay("generic-pool", vector)
  }
}

///|
test "the random traces answer as SQLAlchemy's pool does" {
  for group in sqlalchemy_traces {
    for vector in group {
      replay("SQLAlchemy", vector)
    }
  }
}

///|
test "the random traces answer as generic-pool does" {
  for group in generic_pool_traces {
    for vector in group {
      replay("generic-pool", vector)
    }
  }
}

///|
test "the traces with a broken resource answer as generic-pool does" {
  // Only the reference that discards at once: the other marks a dropped connection for
  // replacement at the next borrow, so what it hands out after a drop is its own
  // bookkeeping rather than the decision being compared.
  for group in generic_pool_broken {
    for vector in group {
      replay("generic-pool", vector)
    }
  }
}

///|
test "the two references answer the same plan the same way" {
  // Two pools written by other people in other languages, driven by the same steps: where
  // the plan asks the same question they have to agree, or one of them is not the oracle
  // the other is taken for. The age plans are not compared by name or by limit — one
  // retires by lifetime and the other by idle time — only by what they handed out.
  assert_eq(sqlalchemy_vectors.length(), generic_pool_vectors.length())
  for at in 0..<sqlalchemy_vectors.length() {
    assert_eq(sqlalchemy_vectors[at].takes, generic_pool_vectors[at].takes)
    assert_eq(sqlalchemy_vectors[at].gauges, generic_pool_vectors[at].gauges)
  }
  // The traces ask the same question of both, so they have to answer alike too.
  assert_eq(sqlalchemy_traces.length(), generic_pool_traces.length())
  for group in 0..<sqlalchemy_traces.length() {
    assert_eq(
      sqlalchemy_traces[group].length(),
      generic_pool_traces[group].length(),
    )
    for at in 0..<sqlalchemy_traces[group].length() {
      let one = sqlalchemy_traces[group][at]
      let other = generic_pool_traces[group][at]
      assert_eq(one.name, other.name)
      assert_eq(one.takes, other.takes)
      assert_eq(one.gauges, other.gauges)
    }
  }
}
