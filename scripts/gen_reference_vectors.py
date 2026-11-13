"""Run the two reference pools over their plans and write what they answered into
`src/reference_vectors_wbtest.mbt`.

    python3 scripts/gen_reference_vectors.py

The hand-written plans beside the reference scripts pin the decisions one at a time:
reuse order, the ceiling, the two ages, a broken resource. The random traces go after the
combinations no plan thinks of -- every legal ordering of take, give and drop over one to
four seats, drawn from a fixed seed so the recording is the same everywhere. Both are
recorded once and replayed on every target, with neither reference installed.

The output is committed; CI regenerates it and fails when the tree differs, which is what
ties the data to the references. The file is formatted afterwards, so what the script
writes and what the tree holds are the same thing only after `moon fmt` has run -- which
this script does itself.
"""

import argparse
import json
import pathlib
import random
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REFERENCE = ROOT / "scripts" / "reference"
OUT = ROOT / "src" / "reference_vectors_wbtest.mbt"
TRACES = REFERENCE / "traces.json"
BROKEN = REFERENCE / "broken_traces.json"
TRACE_SEED = 20261114
TRACE_COUNT = 30
BROKEN_COUNT = 10
TRACE_STEPS = 12
PER_GROUP = 10

# The module name of a plan file and the script that drives that pool.
REFERENCES = [
    ("sqlalchemy", "sqlalchemy_queue_pool.py"),
    ("generic_pool", "generic_pool.mjs"),
]


def traces(drops, seed, count, steps_of_each):
    """Legal orderings of take and give, with or without drop, from a seed.

    Every step is at the same instant, so the recording leans on neither reference's
    clock and needs no sleep: what is compared is the bookkeeping, which is where a pool
    over-issues a seat or loses one. `of` names a take by its index, so a step that hands
    back a resource the plan never asked for cannot be written.

    `drop` traces are kept apart from the shared ones: one of the references marks a
    discarded connection for replacement at the next borrow instead of taking it off its
    books, so its hand-outs after a drop are its own bookkeeping. Those traces are
    compared against the reference that discards at once, which is what this package
    does.
    """
    rng = random.Random(seed)
    plans = []
    for number in range(1, count + 1):
        size = rng.randint(1, 4)
        live, steps, takes = [], [], 0
        for _ in range(steps_of_each):
            if live and rng.random() < 0.34:
                index = live.pop(rng.randrange(len(live)))
                op = "drop" if drops and rng.random() < 0.35 else "give"
                steps.append({"op": op, "at": 0, "of": index})
            elif len(live) < size:
                live.append(takes)
                takes += 1
                steps.append({"op": "take", "at": 0})
            else:
                steps.append({"op": "give", "at": 0, "of": live.pop(0)})
        if len(live) == size:
            # One ask past the ceiling, which neither side can serve: it has to answer
            # "no", and nothing later in the trace may refer to it.
            steps.append({"op": "take", "at": 0})
        plans.append(
            {
                "name": f"trace {number} over {size} seats",
                "size": size,
                "idle": size,
                "keep_ms": 0,
                "life_ms": 0,
                "steps": steps,
            }
        )
    return plans


def record(script, python, node, plan):
    if script.endswith(".py"):
        command = [python, str(REFERENCE / script), "--plan", str(plan)]
    else:
        command = [node, str(REFERENCE / script), "--plan", str(plan)]
    done = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"{script} failed:\n{done.stderr.strip()}")
    return json.loads(done.stdout)


def span(ms):
    return "@moondate.Span::new()" if ms == 0 else f"@moondate.Span::new(millis={ms}L)"


def vector_lines(scenario, indent):
    """One recorded plan, as the record literal `reference_wbtest.mbt` declares."""
    pad = " " * indent
    out = [f"{pad}{{", f'{pad}  name: "{scenario["name"]}",', f"{pad}  limits: {{"]
    out.append(f'{pad}    size: {scenario["size"]},')
    out.append(f'{pad}    idle: {scenario["idle"]},')
    out.append(f"{pad}    keep: {span(scenario['keep_ms']) },")
    out.append(f"{pad}    life: {span(scenario['life_ms']) },")
    out.extend([f"{pad}  }},", f"{pad}  steps: ["])
    for step in scenario["steps"]:
        # The plans count milliseconds; a pool's clock is nanoseconds.
        at = "{:,}L".format(step["at"] * 1_000_000).replace(",", "_")
        if step["op"] == "take":
            out.append(f"{pad}    Take({at}),")
        elif step["op"] == "give":
            out.append(f"{pad}    Give({at}, {step['of']}),")
        elif step["op"] == "drop":
            out.append(f"{pad}    Drop({at}, {step['of']}),")
        else:
            out.append(f"{pad}    Pause({at}),")
    out.append(f"{pad}  ],")
    out.append(f"{pad}  takes: [" + ", ".join(str(t) for t in scenario["takes"]) + "],")
    out.append(
        f"{pad}  gauges: ["
        + ", ".join(f"({idle}, {live})" for idle, live in scenario["gauges"])
        + "],"
    )
    out.append(f"{pad}}},")
    return out


def plans_of(name, recording):
    out = ["///|", f"let {name} : Array[Vector] = ["]
    for scenario in recording["scenarios"]:
        out.extend(vector_lines(scenario, 2))
    out.append("]")
    return out


def traces_of(name, recording):
    """The traces in groups, each its own function: one array of hundreds of records is
    one initialiser too big for wasm."""
    groups = [
        recording["scenarios"][at : at + PER_GROUP]
        for at in range(0, len(recording["scenarios"]), PER_GROUP)
    ]
    out = []
    for number, group in enumerate(groups, 1):
        out.extend(["///|", f"fn {name}_{number}() -> Array[Vector] {{", "  ["])
        for scenario in group:
            out.extend(vector_lines(scenario, 4))
        out.extend(["  ]", "}", ""])
    # A plain array of the groups rather than a spread of them: the compiler's unused
    # check does not see a spread that calls a function, and a warning here is an error.
    out.extend(["///|", f"let {name} : Array[Array[Vector]] = ["])
    for number in range(1, len(groups) + 1):
        out.append(f"  {name}_{number}(),")
    out.append("]")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--python", default=sys.executable)
    ap.add_argument("--node", default="node")
    ap.add_argument("--moon", default="moon")
    args = ap.parse_args()

    shared = traces(False, TRACE_SEED, TRACE_COUNT, TRACE_STEPS)
    broken = traces(True, TRACE_SEED + 1, BROKEN_COUNT, TRACE_STEPS)
    for path, plans in ((TRACES, shared), (BROKEN, broken)):
        path.write_text(json.dumps(plans, indent=2) + "\n", encoding="utf-8", newline="\n")

    # `sqlalchemy` drives the shared traces only; `generic_pool` drives both.
    recordings = []
    for name, script in REFERENCES:
        hand = record(script, args.python, args.node, REFERENCE / f"{name}_plan.json")
        traced = record(script, args.python, args.node, TRACES)
        recordings.append((name, hand, traced, record(script, args.python, args.node, BROKEN) if name == "generic_pool" else None))

    sources = [hand["source"] for _, hand, _, _ in recordings]
    body = [
        "// Generated by `scripts/gen_reference_vectors.py`; do not edit.",
        "//",
        "// What a mature pool of another language answered when the steps in",
        "// `scripts/reference/*.json` were run against it: the four hand-written plans, then",
        "// the random traces. The references are " + " and ".join(sources) + ".",
        "// `reference_wbtest.mbt` replays the same steps against moonpool and compares.",
        "",
    ]
    for name, hand, traced, broken_recording in recordings:
        body.extend(plans_of(f"{name}_vectors", hand))
        body.append("")
        body.extend(traces_of(f"{name}_traces", traced))
        body.append("")
        if broken_recording is not None:
            body.extend(traces_of(f"{name}_broken", broken_recording))
            body.append("")
    OUT.write_text("\n".join(body), encoding="utf-8", newline="\n")
    subprocess.run([args.moon, "fmt"], cwd=ROOT, capture_output=True)
    print(
        f"{OUT.relative_to(ROOT).as_posix()}: {', '.join(sources)}; "
        f"{len(shared)} shared traces and {len(broken)} with a drop, {TRACE_STEPS} moves each"
    )


if __name__ == "__main__":
    main()
