// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The pool, worked by a synthetic client. A pool needs a caller with a clock and
// a runtime; this is one, small enough to run inside a browser tab: time advances
// in fixed steps, arrivals are counted, and every answer the pool gives is tallied.
//
// The rules of the pool are all in the package. What is here is only the client.

///|
/// One run of the simulation, as JSON.
///
/// `spec` is `k=v` pairs separated by commas:
/// `size`, `idle`, `keep` (seconds), `life` (seconds), `rate` (requests a second),
/// `hold` (milliseconds a borrow lasts), `ticks`, `seed`, `fail` (share of makes
/// that fail), `breaker` (1 to put one in front), `cpu` (thousandths).
pub fn run(spec : String) -> String {
  let cfg = Config::parse(spec)
  let pool : @moonpool.Pool[Int32] = @moonpool.Pool::new(
    limits=@moonpool.Limits::new(
      size=cfg.size,
      idle=cfg.idle,
      keep=@moondate.Span::new(seconds=cfg.keep.to_int64()),
      life=@moondate.Span::new(seconds=cfg.life.to_int64()),
    ),
    ward=if cfg.breaker {
      @moonpool.Ward::new(breaker=@moonward.Breaker::new())
    } else {
      @moonpool.ward
    },
  )
  let rng = Rng::new(cfg.seed)
  let loans : Array[(Int32, Int64)] = []
  let mut next_id = 1
  let mut carry = 0.0
  let mut ready = 0
  let mut made = 0
  let mut failed = 0
  let mut waits = 0
  let mut laters = 0
  let mut sheds = 0
  let mut stales = 0
  let mut evicted = 0
  let mut closed = 0
  let mut returned = 0
  let mut peak_busy = 0
  let mut peak_idle = 0
  let ticks = Ticks::new()
  let step : Int64 = 100_000_000L
  for tick = 0; tick < cfg.ticks; tick = tick + 1 {
    let now = tick.to_int64() * step
    // Give back what is due, oldest loan first.
    let keeping : Array[(Int32, Int64)] = []
    for loan in loans {
      if loan.1 <= now {
        returned = returned + 1
        if !pool.give(loan.0, now) {
          closed = closed + 1
        }
      } else {
        keeping.push(loan)
      }
    }
    loans.clear()
    for loan in keeping {
      loans.push(loan)
    }
    // Requests this step, carried over so a rate below one a step still arrives.
    // The burst pattern is eight steps at two and a half times the rate followed by
    // twelve at nothing, which averages back to exactly one.
    let wobble = if !cfg.burst {
      1.0
    } else if tick % 20 < 8 {
      2.5
    } else {
      0.0
    }
    carry = carry + cfg.rate * 100.0 * wobble
    let mut make_here = 0
    let mut wait_here = 0
    let mut shed_here = 0
    while carry >= 1000.0 {
      carry = carry - 1000.0
      match pool.take(now, roll=rng.next(), cpu=cfg.cpu) {
        Ready(id) => {
          ready = ready + 1
          loans.push((id, now + cfg.hold.to_int64() * 1_000_000L))
        }
        Stale(id) => {
          stales = stales + 1
          ignore(id)
          closed = closed + 1
        }
        Make => {
          make_here = make_here + 1
          if rng.next() < cfg.fail {
            failed = failed + 1
            pool.unmade(now, roll=rng.next())
          } else {
            made = made + 1
            let id = next_id
            next_id = next_id + 1
            pool.made(id, now)
            loans.push((id, now + cfg.hold.to_int64() * 1_000_000L))
          }
        }
        Wait => {
          waits = waits + 1
          wait_here = wait_here + 1
        }
        Later(_) => laters = laters + 1
        Shed => {
          sheds = sheds + 1
          shed_here = shed_here + 1
        }
      }
    }
    // The eviction timer, which a runtime would run on its own schedule.
    evicted = evicted + pool.evict(now).length()
    let busy = pool.busy()
    let idle = pool.idle()
    if busy > peak_busy {
      peak_busy = busy
    }
    if idle > peak_idle {
      peak_idle = idle
    }
    ticks.push(
      Tick::new(busy, idle, make_here, wait_here, shed_here, pool.refusal(now)),
    )
  }
  let out = StringBuilder()
  out.write_string("{\"ok\":true,\"config\":")
  out.write_string(cfg.to_json())
  out.write_string(",\"totals\":{\"ready\":")
  out.write_string(ready.to_string())
  out.write_string(",\"made\":")
  out.write_string(made.to_string())
  out.write_string(",\"failed\":")
  out.write_string(failed.to_string())
  out.write_string(",\"wait\":")
  out.write_string(waits.to_string())
  out.write_string(",\"later\":")
  out.write_string(laters.to_string())
  out.write_string(",\"shed\":")
  out.write_string(sheds.to_string())
  out.write_string(",\"stale\":")
  out.write_string(stales.to_string())
  out.write_string(",\"evicted\":")
  out.write_string(evicted.to_string())
  out.write_string(",\"closed\":")
  out.write_string(closed.to_string())
  out.write_string(",\"returned\":")
  out.write_string(returned.to_string())
  out.write_string(",\"peakBusy\":")
  out.write_string(peak_busy.to_string())
  out.write_string(",\"peakIdle\":")
  out.write_string(peak_idle.to_string())
  out.write_string("},\"ticks\":")
  out.write_string(ticks.finish())
  out.write_string("}")
  out.to_string()
}

///|
/// The knobs, with the values the page starts from.
priv struct Config {
  mut size : Int32
  mut idle : Int32
  mut keep : Int32
  mut life : Int32
  mut rate : Double
  mut hold : Int32
  mut ticks : Int32
  mut seed : Int64
  mut fail : Double
  mut breaker : Bool
  mut burst : Bool
  mut cpu : Int32
}

///|
fn Config::parse(spec : String) -> Config {
  let c : Config = {
    size: 20,
    idle: 10,
    keep: 1800,
    life: 0,
    rate: 8.0,
    hold: 250,
    ticks: 240,
    seed: 7L,
    fail: 0.0,
    breaker: false,
    burst: true,
    cpu: 200,
  }
  for pair in spec.split(",") {
    let kv = pair.split("=").to_array()
    if kv.length() != 2 {
      continue
    }
    let v = kv[1]
    let n = sv_int(v)
    match kv[0] {
      "size" => c.size = n
      "idle" => c.idle = n
      "keep" => c.keep = n
      "life" => c.life = n
      "rate" => c.rate = n.to_double()
      "hold" => c.hold = n
      "ticks" => c.ticks = n
      "seed" => c.seed = n.to_int64()
      "fail" => c.fail = n.to_double() / 100.0
      "breaker" => c.breaker = n == 1
      "burst" => c.burst = n == 1
      "cpu" => c.cpu = n
      _ => ()
    }
  }
  c
}

///|
fn Config::to_json(self : Config) -> String {
  "{\"size\":" +
  self.size.to_string() +
  ",\"idle\":" +
  self.idle.to_string() +
  ",\"keep\":" +
  self.keep.to_string() +
  ",\"life\":" +
  self.life.to_string() +
  ",\"rate\":" +
  self.rate.to_string() +
  ",\"hold\":" +
  self.hold.to_string() +
  ",\"ticks\":" +
  self.ticks.to_string() +
  ",\"fail\":" +
  self.fail.to_string() +
  ",\"breaker\":" +
  (if self.breaker { "true" } else { "false" }) +
  ",\"burst\":" +
  (if self.burst { "true" } else { "false" }) +
  ",\"cpu\":" +
  self.cpu.to_string() +
  "}"
}

///|
/// One step of the trace.
priv struct Tick {
  busy : Int32
  idle : Int32
  make : Int32
  wait : Int32
  shed : Int32
  refusal : Double
}

///|
fn Tick::new(
  busy : Int32,
  idle : Int32,
  make : Int32,
  wait : Int32,
  shed : Int32,
  refusal : Double,
) -> Tick {
  { busy, idle, make, wait, shed, refusal, }
}

///|
/// The steps, collected as a JSON array.
priv struct Ticks {
  buf : StringBuilder
  mut n : Int32
}

///|
fn Ticks::new() -> Ticks {
  { buf: StringBuilder(), n: 0, }
}

///|
fn Ticks::push(self : Ticks, t : Tick) -> Unit {
  if self.n > 0 {
    self.buf.write_char(',')
  }
  self.n = self.n + 1
  self.buf.write_string("{\"busy\":")
  self.buf.write_string(t.busy.to_string())
  self.buf.write_string(",\"idle\":")
  self.buf.write_string(t.idle.to_string())
  self.buf.write_string(",\"make\":")
  self.buf.write_string(t.make.to_string())
  self.buf.write_string(",\"wait\":")
  self.buf.write_string(t.wait.to_string())
  self.buf.write_string(",\"shed\":")
  self.buf.write_string(t.shed.to_string())
  self.buf.write_string(",\"refusal\":")
  self.buf.write_string(t.refusal.to_string())
  self.buf.write_string("}")
}

///|
fn Ticks::finish(self : Ticks) -> String {
  "[" + self.buf.to_string() + "]"
}

///|
/// A small deterministic generator, so the same spec always draws the same run.
priv struct Rng {
  mut state : UInt64
}

///|
fn Rng::new(seed : Int64) -> Rng {
  { state: seed.reinterpret_as_uint64() | 1UL, }
}

///|
fn Rng::next(self : Rng) -> Double {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  (self.state >> 11).to_double() / 9007199254740992.0
}

///|
/// The digits of a `k=v` value, which is all the spec carries.
fn sv_int(s : StringView) -> Int32 {
  let mut v = 0
  for c in s {
    let d = c.to_int() - '0'.to_int()
    if d >= 0 && d <= 9 {
      v = v * 10 + d
    }
  }
  v
}
