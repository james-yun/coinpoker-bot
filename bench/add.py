#!/usr/bin/env python3
"""Adds a past decision to the benchmark (bench/spots.json), with the answer it should get.

Usage: bench/add.py <run-dir>/<shot> --id <name> --expect <action[,action...]> --note "<why>"
                    [--append "<extra context>"]

<shot> is a decision's screenshot name without .png (e.g. /tmp/poker/2026-11-25_113747/h051_river_turn).
--expect lists the acceptable actions: fold, call (or check), raise, 33, 50, 75, max, 2x..4x, or a group:
bet (any bet/raise), big (75/max), value (50/75/max), small (33/min raise).
--append adds text to the context the decider originally got (e.g. stats it didn't have yet).
The screenshot is copied to bench/spots/ (kept out of git). The benchmark rebuilds the context from it
with the current engine (cards, hand strength, the price of a call, saved stats), so reader changes
are tested too; the preflop summary the decider got is kept from the original.
"""
import argparse, json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import BENCH, saved_decision

ap = argparse.ArgumentParser()
ap.add_argument("shot")
ap.add_argument("--id", required=True)
ap.add_argument("--expect", required=True)
ap.add_argument("--note", default="")
ap.add_argument("--append", default="")
a = ap.parse_args()

shot = a.shot[:-4] if a.shot.endswith(".png") else a.shot
saved = saved_decision(shot + ".txt")
if not saved:
    sys.exit(f"{shot}.txt isn't a model turn decision")
context, played = saved
prefix = context.split("Your cards:")[0].strip()       # what preflop happened (not readable from one screenshot)
os.makedirs(os.path.join(BENCH, "spots"), exist_ok=True)
image = f"spots/{a.id}.png"
shutil.copyfile(shot + ".png", os.path.join(BENCH, image))   # full size: the card reader needs it

path = os.path.join(BENCH, "spots.json")
spots = json.load(open(path)) if os.path.exists(path) else []
spots = [s for s in spots if s["id"] != a.id]
spots.append({"id": a.id, "image": image, "prefix": prefix, "append": a.append, "saved_context": context,
              "expect": a.expect.split(","),
              "note": a.note, "source": shot.split("/poker/")[-1], "played": played})
json.dump(spots, open(path, "w"), indent=1, ensure_ascii=False)
print(f"added {a.id} (played {played}, expect {a.expect}); {len(spots)} spots")
