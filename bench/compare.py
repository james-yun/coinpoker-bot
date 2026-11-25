#!/usr/bin/env python3
"""Compares two --all runs decision by decision (e.g. the default against a variant, on the same runs).

Usage: bench/compare.py bench/results/<a>_all_*.json bench/results/<b>_all_*.json

Lists every decision where the two answers differ, with b's reason. Run the same variant twice to see
how often the model changes its mind with nothing changed (the noise floor) before trusting a difference.
"""
import json, sys

a, b = (json.load(open(p)) for p in sys.argv[1:3])
ra = {r["id"]: r for r in a["rows"]}
rb = {r["id"]: r for r in b["rows"]}
common = [i for i in ra if i in rb]
diff = [i for i in common if ra[i]["now"] != rb[i]["now"]]
name = lambda d: (d["variant"] or "default").split("/")[-1]
for i in diff:
    reason = " ".join(rb[i]["reply"].splitlines()[:-1])[:120]
    print(f"- {i}: {name(a)} {ra[i]['now']}, {name(b)} {rb[i]['now']} (played {ra[i]['played']})   {reason}")
print(f"\n{len(diff)} of {len(common)} decisions differ between {name(a)} and {name(b)}")
