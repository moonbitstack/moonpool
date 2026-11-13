"""Drive SQLAlchemy's QueuePool through the plan in `sqlalchemy_plan.json` and print
what it did, as JSON.

This is the reference half of the differential suite in `src/reference_wbtest.mbt`:
the pool here is someone else's, mature and widely deployed, and the steps are run
against it with a fake DBAPI so that only the pooling decisions are observed.

    pip install -r scripts/reference/requirements.txt
    python3 scripts/reference/sqlalchemy_queue_pool.py > /tmp/sqlalchemy.json

Limit mapping, and why: `size` is `pool_size` with no overflow, so the pool blocks
instead of opening an extra connection; `life` is `recycle`, the age at which a
connection is thrown away and made again; `keep` has no counterpart here, so plans
that use it are for the other reference. The order is set to LIFO, which this pool
offers as an option and moonpool does by default.
"""

import argparse
import json
import pathlib
import sys
import time

from sqlalchemy.pool import QueuePool

PLAN = pathlib.Path(__file__).with_name("sqlalchemy_plan.json")
WAIT = 0.06  # seconds a full pool is allowed to block before it answers "no"


class Wrapped:
    """A connection that records whether the pool closed it."""

    def __init__(self, ident):
        self.id = ident
        self.closed = False

    def close(self):
        self.closed = True

    def rollback(self):
        pass

    def cursor(self):
        raise RuntimeError("the pool never runs a statement")


def run(scenario):
    made = [0]

    def creator():
        made[0] += 1
        return Wrapped(made[0])

    pool = QueuePool(
        creator,
        pool_size=scenario["size"],
        max_overflow=0,
        timeout=WAIT,
        use_lifo=True,
        recycle=scenario["life_ms"] / 1000 or -1,
        reset_on_return=None,
    )
    start = time.monotonic()
    held = {}
    takes = []
    gauges = []

    for step in scenario["steps"]:
        delay = start + step["at"] / 1000 - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        op = step["op"]
        if op == "take":
            try:
                conn = pool.connect()
                ident = conn.dbapi_connection.id
                held[len(takes)] = conn
                takes.append(ident)
            except Exception:
                takes.append(-1)
            gauges.append([pool.checkedin(), pool.checkedin() + pool.checkedout()])
        elif op == "give":
            held.pop(step["of"]).close()
        elif op == "drop":
            conn = held.pop(step["of"])
            conn.invalidate()
            conn.close()

    for conn in held.values():
        conn.close()
    pool.dispose()
    return {
        "name": scenario["name"],
        "size": scenario["size"],
        "idle": scenario["idle"],
        "keep_ms": scenario["keep_ms"],
        "life_ms": scenario["life_ms"],
        "steps": scenario["steps"],
        "takes": takes,
        "gauges": gauges,
    }


def main():
    import sqlalchemy

    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=str(PLAN))
    args = ap.parse_args()
    plan = json.loads(pathlib.Path(args.plan).read_text(encoding="utf-8"))
    print(
        json.dumps(
            {
                "source": f"SQLAlchemy {sqlalchemy.__version__} QueuePool",
                "scenarios": [run(s) for s in plan],
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
