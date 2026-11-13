// Drive node-generic-pool through the plan in `generic_pool_plan.json` and print
// what it did, as JSON.
//
// The reference half of the differential suite in `src/reference_wbtest.mbt`, next
// to the SQLAlchemy one: a second, unrelated implementation of the same idea, with
// its own author's reading of it. Only the pooling decisions are observed, because
// the factory hands out numbered handles and does nothing else.
//
// Limit mapping, and why: `size` is `max`, the ceiling on handles in existence;
// `keep` is `idleTimeoutMillis`, the age at which an idle handle is destroyed, so
// plans that age an idle handle belong here; there is no lifetime knob, so plans
// that use one are for the other reference. Last-in-first-out is `fifo: false`.
//
//   npm install --prefix scripts/reference
//   node scripts/reference/generic_pool.mjs

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createPool } from "generic-pool";

const HERE = dirname(fileURLToPath(import.meta.url));
const PLAN = JSON.parse(readFileSync(join(HERE, "generic_pool_plan.json"), "utf8"));
const WAIT = 60;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));

async function run(scenario) {
  let made = 0;
  const pool = createPool(
    {
      create: async () => ({ id: ++made }),
      destroy: async () => {},
      validate: async () => true,
    },
    {
      max: scenario.size,
      min: 0,
      fifo: false,
      acquireTimeoutMillis: WAIT,
      idleTimeoutMillis: scenario.keep_ms,
      evictionRunIntervalMillis: scenario.keep_ms > 0 ? 50 : 0,
    },
  );
  const start = Date.now();
  const held = new Map();
  const takes = [];
  const gauges = [];

  for (const step of scenario.steps) {
    await sleep(start + step.at - Date.now());
    if (step.op === "take") {
      try {
        const handle = await pool.acquire();
        held.set(takes.length, handle);
        takes.push(handle.id);
      } catch {
        takes.push(-1);
      }
      gauges.push([pool.available, pool.size]);
    } else if (step.op === "give") {
      const handle = held.get(step.of);
      held.delete(step.of);
      await pool.release(handle);
    } else if (step.op === "drop") {
      const handle = held.get(step.of);
      held.delete(step.of);
      await pool.destroy(handle);
    }
  }

  for (const handle of held.values()) {
    await pool.release(handle);
  }
  await pool.clear();
  return { ...scenario, takes, gauges };
}

const scenarios = [];
for (const scenario of PLAN) {
  scenarios.push(await run(scenario));
}
process.stdout.write(
  JSON.stringify({
    source: "node-generic-pool 3.9.0",
    scenarios,
  }),
);
process.exit(0);
