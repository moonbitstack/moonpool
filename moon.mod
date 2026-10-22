name = "moonbitstack/moonpool"

version = "0.3.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonpool"

license = "Apache-2.0"

keywords = [
  "pool",
  "connection-pool",
  "circuit-breaker",
  "backoff",
  "moonbit",
]

description = "Resource pools for MoonBit: which resource to hand out, when to make another, which to let go, guarded by the breakers, limiters and backoff of moonward. The clock and the randomness are passed in, so every sequence is reproducible and none of it touches I/O."

preferred_target = "wasm-gc"

import {
  "moonbitstack/moondate@0.1.0",
  "moonbitstack/moonward@0.1.0",
}
