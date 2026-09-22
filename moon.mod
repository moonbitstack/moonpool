name = "moonbitstack/moonpool"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moonpool"

license = "Apache-2.0"

keywords = [ "pool", "retry", "backoff", "ratelimit", "moonbit" ]

description = "moonpool — resource pools, backoff and flow control for MoonBit. The bookkeeping of holding a limited number of things, of deciding when to try again, and of not going too fast — with the clock and the randomness passed in, so every sequence is reproducible and none of it touches I/O."

preferred_target = "wasm-gc"

import {
  "moonbitstack/moondate@0.1.0",
}
