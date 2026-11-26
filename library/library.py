#!/usr/bin/env python3
"""Plays the bot through Pluribus's decisions and scores how often it chooses what Pluribus chose.

  library/library.py [--sample 200] [--variant prompts/x.sh] [--model m] [--jobs 6] [--seed 1]
  library/library.py --compare <results A.json> <results B.json>

The hands are the 10,000 six-max, 100bb hands Pluribus (the poker AI from Brown & Sandholm, 2019)
played against professionals, in the open PHH format (github.com/uoftcprg/phh-dataset, data/pluribus).
Every Pluribus decision becomes a spot described in text, the way the bot sees a table: position,
the betting so far, cards, its exact hand and draws, and the price of a call. Then:
  - preflop spots the charts cover are scored exactly from the chart's frequencies (with the bot's
    adjustments: raise at 15%+, 3-bet or fold from the small blind), for every hand in the library;
  - everything else (postflop, limped and multiway preflop) goes to the model, on a sample
    stratified by street and by whether there's a bet to face.
Scores: agreement on fold / check-call / bet-raise, by street and situation; sizing agreement on bets
(small < 45% pot, medium, large > 85% or all-in); and the disagreements that matter most (folding a
strong hand Pluribus played for value, or putting chips in where it folded a weak one).

Agreement isn't winnings: Pluribus mixes its strategy, and it played professionals, while some of the
bot's rules exploit play-money players. Use it to find gross errors and to compare variants.
"""
import argparse, ast, glob, json, os, random, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from common import action_of  # noqa: E402

DATA = os.environ.get("PLURIBUS_DATA", os.path.expanduser("~/dev/third_party/phh-dataset/data/pluribus"))
ENGINE = os.path.join(ROOT, "engine")
DECIDE = os.path.join(ROOT, "decide.sh")
CHARTS = json.load(open(os.path.join(ROOT, "preflop_charts.json")))["6"]
RESULTS = os.path.join(ROOT, "library", "results")
POS = ["SB", "BB", "UTG", "HJ", "CO", "BTN"]          # p1..p6 with blinds 50/100
STREETS = ["preflop", "flop", "turn", "river"]
SYM = {"s": "♠", "h": "♥", "d": "♦", "c": "♣"}
TEXT_NOTE = "There's no screenshot: the table is described in text (ignore what the instructions say about the picture)."


def cards(s):
    return [s[i:i + 2] for i in range(0, len(s), 2)]


def pretty(c):
    return c[0] + SYM[c[1]]


def parse_phh(path):
    out = {}
    for line in open(path):
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().replace("true", "True").replace("false", "False")
        try:
            out[k.strip()] = ast.literal_eval(v)
        except (ValueError, SyntaxError):
            pass
    return out


def bb(chips):
    return f"{chips / 100:g}bb"


def decisions(path):
    """Pluribus's decision points in one hand, each with the state before it acted."""
    h = parse_phh(path)
    players = h.get("players", [])
    if "Pluribus" not in players or len(players) != 6:
        return []
    me = players.index("Pluribus")
    stacks = list(h["starting_stacks"])
    put_street = [0] * 6                              # this street
    put_total = [0] * 6
    for i, b in enumerate(h["blinds_or_straddles"]):
        put_street[i] = put_total[i] = b
        stacks[i] -= b
    folded = [False] * 6
    hole, board, street = {}, [], 0
    history = [[] for _ in STREETS]                   # text per street
    raises_pre = []                                   # (seat) of preflop raisers, in order
    calls_pre = []
    out = []
    for n, a in enumerate(h["actions"]):
        t = a.split()
        if t[0] == "d":
            if t[1] == "dh":
                hole[int(t[2][1:]) - 1] = cards(t[3])
            elif t[1] == "db":
                board += cards(t[2])
                street += 1
                put_street = [0] * 6
            continue
        seat = int(t[0][1:]) - 1
        if t[1] == "sm":
            continue
        pot = sum(put_total)
        to_call = max(put_street) - put_street[seat]
        if seat == me:
            if t[1] == "f":
                expert, size = "fold", None
            elif t[1] == "cc":
                expert, size = "call", None
            else:
                to = int(t[2])
                added = to - put_street[seat]
                allin = added >= stacks[seat]
                base = pot + to_call                    # the pot once we've called
                frac = (to - max(put_street)) / base if base else 0
                size = "large" if allin or frac > 0.85 else "small" if frac < 0.45 else "medium"
                expert = "raise"
            out.append({
                "id": f"{os.path.relpath(path, DATA)[:-4]}#{n}", "street": STREETS[street], "pos": POS[me],
                "hole": hole.get(me), "board": list(board), "pot": pot, "to_call": to_call, "stack": stacks[me],
                "in_hand": sum(1 for i in range(6) if not folded[i]),
                "history": [list(x) for x in history[:street + 1]],
                "raisers": list(raises_pre), "callers": list(calls_pre),
                "expert": expert, "size": size, "facing": to_call > 0})
        # apply the action
        who = "you" if seat == me else POS[seat]
        if t[1] == "f":
            folded[seat] = True
            history[street].append(f"{who} folds")
        elif t[1] == "cc":
            amount = min(to_call, stacks[seat])
            put_street[seat] += amount
            put_total[seat] += amount
            stacks[seat] -= amount
            history[street].append(f"{who} {'calls ' + bb(amount) if amount else 'checks'}")
            if street == 0 and amount:
                calls_pre.append(seat)
        else:
            to = int(t[2])
            amount = to - put_street[seat]
            put_street[seat] = to
            put_total[seat] += amount
            stacks[seat] -= amount
            verb = "bets" if street > 0 and max(put_street[i] for i in range(6) if i != seat) == 0 else "raises to"
            history[street].append(f"{who} {verb} {bb(to)}" + (" (all-in)" if stacks[seat] == 0 else ""))
            if street == 0:
                raises_pre.append(seat)
    return out


def chart_key(d):
    """The preflop chart spot for a decision, or None (the bot asks the model there)."""
    if d["street"] != "preflop":
        return None
    me = POS.index(d["pos"])
    raisers = [s for s in d["raisers"] if s != me]
    callers = [s for s in d["callers"] if s != me]
    if callers:
        return None
    if not d["raisers"]:
        return f"RFI:{d['pos']}" if d["pos"] != "BB" else None
    if len(d["raisers"]) == 1 and raisers:
        return f"VO:{d['pos']}:{POS[raisers[0]]}"
    if len(d["raisers"]) == 2 and d["raisers"][0] == me:
        return f"V3:{d['pos']}:{POS[d['raisers'][1]]}"
    return None


def hand_class(hole):
    r = "23456789TJQKA"
    a, b = sorted(hole, key=lambda c: r.index(c[0]), reverse=True)
    if a[0] == b[0]:
        return a[0] * 2
    return a[0] + b[0] + ("s" if a[1] == b[1] else "o")


def chart_probs(key, hole):
    """The bot's probability of fold / call / raise at a chart spot."""
    spot = CHARTS.get(key)
    if not spot:
        return None
    f = spot["hands"].get(hand_class(hole))
    if f is None:
        return None
    p = {"fold": 0.0, "call": 0.0, "raise": 0.0}
    for label, x in zip(spot["actions"], f):
        kind = label.split()[0]
        p["fold" if kind == "fold" else "call" if kind in ("call", "check") else "raise"] += x
    if p["raise"] >= 0.15:                                   # mixed spots lean to raising
        p = {"fold": 0.0, "call": 0.0, "raise": 1.0}
    if key.startswith("VO:SB:") and p["call"] > 0:           # small blind: 3-bet or fold
        p["raise"] += p["call"]
        p["call"] = 0.0
    return p


def strengths(ds):
    """Hand-strength lines from the engine, for spots with a board."""
    lines = [" ".join(pretty(c) for c in d["hole"]) + " | " + " ".join(pretty(c) for c in d["board"]) for d in ds]
    out = subprocess.run([ENGINE, "--hand-strength"], input="\n".join(lines) + "\n", capture_output=True, text=True).stdout
    return out.split("\n")[:len(ds)]


def context(d, strength):
    parts = [TEXT_NOTE, f"6-handed, blinds 0.5/1bb, everyone started with 100bb; {d['in_hand']} players are still in. You are {d['pos']}."]
    for i, acts in enumerate(d["history"]):
        if i == 0:
            parts.append("Preflop: " + (", ".join(acts) if acts else "nothing yet") + ".")
        else:
            parts.append(f"{STREETS[i].capitalize()} {' '.join(pretty(c) for c in d['board'][:2 + i])}: " + (", ".join(acts) if acts else "nothing yet") + ".")
    kind = "pair" if d["hole"][0][0] == d["hole"][1][0] else "suited" if d["hole"][0][1] == d["hole"][1][1] else "offsuit"
    parts.append(f"Your cards: {pretty(d['hole'][0])} {pretty(d['hole'][1])} ({kind}). Board: "
                 + (" ".join(pretty(c) for c in d["board"]) + "." if d["board"] else "none (preflop)."))
    if strength:
        parts.append(strength)
    if d["to_call"]:
        x, pot = d["to_call"] / 100, d["pot"] / 100
        line = f"Facing a {'raise' if d['street'] == 'preflop' else 'bet'}: call {x:g} into a pot of {pot:g} (bets included), so you need {100 * x / (pot + x):.0f}% equity"
        if d["street"] != "preflop" and pot > x:
            line += f"; the bet is about {100 * x / (pot - x):.0f}% of the pot before it"
        parts.append(line + ".")
    parts.append(f"Your stack: {d['stack'] / 100:g}bb behind.")
    return " ".join(parts)


def bot_kind(token, facing):
    if token in (None, "timeout"):
        return None, None
    if token == "fold":
        return ("fold" if facing else "call"), None          # folding with nothing to call = checking
    if token == "call":
        return "call", None
    size = {"33": "small", "50": "medium", "75": "medium", "max": "large", "2x": "small", "25x": "small", "3x": "small",
            "4x": "medium", "raise": "small"}.get(token)
    return "raise", size


def ask(d, ctx, variant, model):
    env = dict(os.environ)
    if variant:
        env["POKER_PROMPT"] = os.path.abspath(variant)
    if model:
        env["POKER_MODEL"] = model
    try:
        out = subprocess.run([DECIDE, "-", "turn", ctx], capture_output=True, text=True, env=env, timeout=90).stdout
    except subprocess.TimeoutExpired:
        out = ""
    return action_of(out), out.strip()


def strong(strength):
    made = (strength or "").split(" Draws:")[0]
    return bool(re.search(r"overpair|two pair using|set of|trips \(|straight|flush|full house|quads", made))


def weak(strength):
    return bool(re.search(r"no pair", strength or "")) and "Draws: none" in (strength or "")


def run(a):
    files = sorted(glob.glob(os.path.join(DATA, "**", "*.phh"), recursive=True))
    if not files:
        sys.exit(f"no hands in {DATA} (git clone https://github.com/uoftcprg/phh-dataset, or set PLURIBUS_DATA)")
    ds = [d for f in files for d in decisions(f) if d["hole"]]
    # 1. chart spots, scored exactly, every one in the library
    chart_rows = []
    for d in ds:
        key = chart_key(d)
        p = chart_probs(key, d["hole"]) if key else None
        if p:
            chart_rows.append({"id": d["id"], "key": key, "hand": hand_class(d["hole"]), "expert": d["expert"], "p": p,
                               "agree": p[d["expert"]]})
    # 2. a stratified sample of the rest for the model
    rest = [d for d in ds if not (chart_key(d) and chart_probs(chart_key(d), d["hole"]))]
    rng = random.Random(a.seed)
    groups = {}
    for d in rest:
        if a.street and d["street"] != a.street or a.facing and d["facing"] != (a.facing == "yes"):
            continue
        groups.setdefault((d["street"], d["facing"]), []).append(d)
    per = max(1, a.sample // len(groups))
    sample = [d for g in sorted(groups) for d in rng.sample(groups[g], min(per, len(groups[g])))]
    st = strengths([d for d in sample if d["board"]])
    it = iter(st)
    for d in sample:
        d["strength"] = next(it) if d["board"] else ""
    print(f"{len(files)} hands, {len(ds)} Pluribus decisions: {len(chart_rows)} chart spots scored exactly; "
          f"{len(sample)} of {len(rest)} others sampled for the model ({a.jobs} at a time)...")
    t0 = time.time()
    with ThreadPoolExecutor(a.jobs) as pool:
        answers = list(pool.map(lambda d: ask(d, context(d, d["strength"]), a.variant, a.model), sample))
    model_rows = []
    for d, (tok, reply) in zip(sample, answers):
        kind, size = bot_kind(tok, d["facing"])
        model_rows.append({"id": d["id"], "street": d["street"], "facing": d["facing"], "expert": d["expert"],
                           "expert_size": d["size"], "bot": kind, "bot_size": size, "agree": float(kind == d["expert"]) if kind else None,
                           "strength": d["strength"], "context": context(d, d["strength"]), "reply": reply})
    report(chart_rows, model_rows, time.time() - t0)
    os.makedirs(RESULTS, exist_ok=True)
    label = os.path.splitext(os.path.basename(a.variant))[0] if a.variant else "default"
    path = os.path.join(RESULTS, time.strftime("%Y%m%d_%H%M%S") + f"_{label}.json")
    json.dump({"variant": a.variant, "model": a.model, "seed": a.seed, "chart": chart_rows, "model_rows": model_rows},
              open(path, "w"), indent=1, ensure_ascii=False)
    print(f"\nsaved {os.path.relpath(path, ROOT)}")


def pct(x):
    return f"{100 * x:.0f}%"


def report(chart_rows, model_rows, secs):
    c = sum(r["agree"] for r in chart_rows) / max(1, len(chart_rows))
    print(f"\nPreflop charts: agree with Pluribus {pct(c)} of {len(chart_rows)} spots (expected value over the chart's mix)")
    for kind in ("RFI", "VO", "V3"):
        rs = [r for r in chart_rows if r["key"].startswith(kind)]
        if rs:
            print(f"  {kind:<4} {pct(sum(r['agree'] for r in rs) / len(rs)):>4} of {len(rs)}")
    rows = [r for r in model_rows if r["agree"] is not None]
    if not rows:
        return
    print(f"\nModel decisions: agree {pct(sum(r['agree'] for r in rows) / len(rows))} of {len(rows)} "
          f"({len(model_rows) - len(rows)} unanswered, {secs:.0f}s)")
    for street in STREETS:
        for facing in (False, True):
            rs = [r for r in rows if r["street"] == street and r["facing"] == facing]
            if rs:
                print(f"  {street:<8} {'facing a bet' if facing else 'no bet yet':<13} {pct(sum(r['agree'] for r in rs) / len(rs)):>4} of {len(rs)}")
    print("\n  what Pluribus did -> what the bot did (rows: Pluribus)")
    kinds = ["fold", "call", "raise"]
    print("            " + "".join(f"{k:>8}" for k in kinds))
    for e in kinds:
        print(f"  {e:<10}" + "".join(f"{sum(1 for r in rows if r['expert'] == e and r['bot'] == b):>8}" for b in kinds))
    both = [r for r in rows if r["expert"] == "raise" and r["bot"] == "raise" and r["expert_size"] and r["bot_size"]]
    if both:
        print(f"  bet sizing, when both bet or raised: same bucket {pct(sum(r['expert_size'] == r['bot_size'] for r in both) / len(both))} of {len(both)}")
    bad = [r for r in rows if (r["bot"] == "fold" and r["expert"] != "fold" and strong(r["strength"]))
           or (r["bot"] in ("call", "raise") and r["expert"] == "fold" and r["facing"] and weak(r["strength"]))]
    if bad:
        print(f"\nDisagreements worth a look ({len(bad)}: folding a strong hand, or paying with nothing):")
        for r in bad[:12]:
            print(f"- {r['id']} ({r['street']}): Pluribus {r['expert']}, bot {r['bot']}. {r['strength']}")
            print(f"    bot: {' '.join(r['reply'].splitlines()[:-1])[:140]}")


def compare(pa, pb):
    a, b = (json.load(open(p)) for p in (pa, pb))
    ra = {r["id"]: r for r in a["model_rows"] if r["agree"] is not None}
    rb = {r["id"]: r for r in b["model_rows"] if r["agree"] is not None}
    common = [i for i in ra if i in rb]
    if not common:
        sys.exit("no spots in common (use the same --seed and --sample)")
    sa, sb = (sum(r[i]["agree"] for i in common) / len(common) for r in (ra, rb))
    name = lambda d: os.path.basename(d["variant"] or "default")
    print(f"{len(common)} spots in common: {name(a)} agrees {pct(sa)}, {name(b)} agrees {pct(sb)} ({100 * (sb - sa):+.1f} points)")
    for street in STREETS:
        ids = [i for i in common if ra[i]["street"] == street]
        if ids:
            x = sum(ra[i]["agree"] for i in ids) / len(ids)
            y = sum(rb[i]["agree"] for i in ids) / len(ids)
            print(f"  {street:<8} {pct(x):>4} -> {pct(y):>4} of {len(ids)}")
    changed = [i for i in common if ra[i]["bot"] != rb[i]["bot"]]
    print(f"\n{len(changed)} decisions changed:")
    for i in changed[:20]:
        print(f"- {i} ({ra[i]['street']}): Pluribus {ra[i]['expert']}; {ra[i]['bot']} -> {rb[i]['bot']}. {ra[i]['strength']}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sample", type=int, default=200, help="model decisions to sample (stratified)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--street", choices=STREETS, help="sample only this street")
    ap.add_argument("--facing", choices=["yes", "no"], help="sample only spots with (yes) or without (no) a bet to face")
    ap.add_argument("--variant")
    ap.add_argument("--model")
    ap.add_argument("--compare", nargs=2, metavar=("A_JSON", "B_JSON"))
    a = ap.parse_args()
    if a.compare:
        compare(*a.compare)
    else:
        run(a)
