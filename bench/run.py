#!/usr/bin/env python3
"""Replays past decisions with a strategy variant.

  bench/run.py [--variant prompts/x.sh] [--repeat 2] [--jobs 4] [--only id,id] [--model m] [--effort e]
      Scores the benchmark: every spot in bench/spots.json (real past decisions, each with the answer it
      should get) is decided again; a spot passes when every repeat picks an accepted action.

  Each spot's context is rebuilt from its screenshot with the current engine (--saved: the original text).

  bench/run.py --all /tmp/poker/<run>... [--variant ...] [--limit N]
      Re-decides every model turn decision in those runs and lists the ones that change: how far a
      prompt change reaches, on hands you actually played.

A variant is a shell file sourced by decide.sh after its defaults, e.g. prompts/lag.sh containing
  POKER_BASE="$POKER_BASE Extra rule."      or a full replacement POKER_BASE="...".
Results go to bench/results/ (one JSON per run) so variants can be compared later.
"""
import argparse, glob, json, os, sys, time
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import BENCH, allowed, decide, fresh_context, saved_decision

ap = argparse.ArgumentParser()
ap.add_argument("--variant")
ap.add_argument("--repeat", type=int, default=2)
ap.add_argument("--jobs", type=int, default=4)
ap.add_argument("--only")
ap.add_argument("--model")
ap.add_argument("--effort")
ap.add_argument("--backend", help="claude-cli, anthropic or openai (see decide.py)")
ap.add_argument("--base-url", help="for the openai backend, e.g. http://localhost:11434/v1")
ap.add_argument("--all", nargs="+", metavar="RUN_DIR")
ap.add_argument("--limit", type=int, default=0)
ap.add_argument("--saved", action="store_true", help="use the context the decider originally got, not a fresh reading")
a = ap.parse_args()
label = os.path.splitext(os.path.basename(a.variant))[0] if a.variant else "default"
if a.backend:
    os.environ["POKER_BACKEND"] = a.backend
    label += f"-{a.backend}"
if a.base_url:
    os.environ["POKER_BASE_URL"] = a.base_url
if a.model: label += f"-{a.model}"
if a.effort: label += f"-{a.effort}"


def run_jobs(jobs):
    with ThreadPoolExecutor(a.jobs) as pool:
        return list(pool.map(lambda j: decide(*j, variant=a.variant, model=a.model, effort=a.effort), jobs))


def save(kind, rows, summary):
    os.makedirs(os.path.join(BENCH, "results"), exist_ok=True)
    path = os.path.join(BENCH, "results", time.strftime("%Y%m%d_%H%M%S") + f"_{kind}_{label}.json")
    json.dump({"variant": a.variant, "model": a.model, "effort": a.effort, "summary": summary, "rows": rows},
              open(path, "w"), indent=1, ensure_ascii=False)
    print(f"\nsaved {os.path.relpath(path)}")


if a.all:
    # every model turn decision in the given runs
    spots = []
    for run in a.all:
        for txt in sorted(glob.glob(os.path.join(run, "h*_turn*.txt"))):
            saved = saved_decision(txt)
            png = txt[:-4] + ".png"
            if saved and os.path.exists(png):
                ctx = saved[0] if a.saved else fresh_context({"image": png, "prefix": saved[0].split("Your cards:")[0].strip()})
                spots.append((os.path.basename(run) + "/" + os.path.basename(txt)[:-4], png, ctx, saved[1]))
    if a.limit:
        spots = spots[-a.limit:]
    print(f"re-deciding {len(spots)} past decisions with {label} ({a.jobs} at a time)...")
    t0 = time.time()
    res = run_jobs([(png, ctx) for _, png, ctx, _ in spots])
    changed = [(sid, played, got, reply) for (sid, _, _, played), (got, reply, _) in zip(spots, res) if got != played]
    for sid, played, got, reply in changed:
        reason = " ".join(reply.splitlines()[:-1])[:110]
        print(f"- {sid}: played {played}, now {got}   {reason}")
    print(f"\n{len(changed)} of {len(spots)} decisions change ({100 * len(changed) // max(1, len(spots))}%), "
          f"{time.time() - t0:.0f}s")
    save("all", [{"id": sid, "played": played, "now": got, "reply": reply}
                 for (sid, _, _, played), (got, reply, _) in zip(spots, res)],
         {"decisions": len(spots), "changed": len(changed)})
    sys.exit()

spots_path = os.path.join(BENCH, "spots.json")
spots = json.load(open(spots_path)) if os.path.exists(spots_path) else []
if not spots:
    sys.exit("the benchmark has no spots yet: add past decisions with bench/add.py <run>/<shot> --id ... --expect ...")
if a.only:
    keep = set(a.only.split(","))
    spots = [s for s in spots if s["id"] in keep]
contexts = {s["id"]: (s["saved_context"] + (" " + s["append"] if s.get("append") else "")) if a.saved else fresh_context(s) for s in spots}
jobs = [(os.path.join(BENCH, s["image"]), contexts[s["id"]]) for s in spots for _ in range(a.repeat)]
print(f"benchmark: {len(spots)} spots x {a.repeat} with {label} ({a.jobs} at a time)...")
t0 = time.time()
res = run_jobs(jobs)
rows, passed = [], 0
for i, s in enumerate(spots):
    got = res[i * a.repeat:(i + 1) * a.repeat]
    ok_set = allowed(s["expect"])
    acts = [g[0] for g in got]
    ok = all(x in ok_set for x in acts)
    passed += ok
    secs = sum(g[2] for g in got) / len(got)
    print(f"{'PASS' if ok else 'FAIL'}  {s['id']:<24} expect {'|'.join(s['expect']):<12} got {', '.join(str(x) for x in acts):<14} {secs:4.1f}s")
    if not ok:
        bad = next(g for g in got if g[0] not in ok_set)
        print(f"      {' '.join(bad[1].splitlines()[:-1])[:150]}")
        if s.get("note"):
            print(f"      why {'|'.join(s['expect'])}: {s['note']}")
    rows.append({"id": s["id"], "expect": s["expect"], "got": acts, "pass": ok, "secs": secs, "context": contexts[s["id"]],
                 "replies": [g[1] for g in got]})
print(f"\n{passed}/{len(spots)} passed with {label}, {time.time() - t0:.0f}s")
save("bench", rows, {"spots": len(spots), "passed": passed})
