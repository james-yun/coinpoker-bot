#!/usr/bin/env python3
"""Grades the bot's postflop decisions with a solver: how much each one gave up, in big blinds.

  grade/grade.py /tmp/poker/<run>... [--iterations 400] [--jobs 2]
  grade/grade.py --compare <bench --all A.json> <bench --all B.json>    (after a grade run)

For every heads-up hand whose preflop came from the charts, the hand is rebuilt and solved from the
flop with GTOpen (examples/grade_hand):
  - ranges: the preflop charts (what each side opened, called or 3-bet with), the bot's own hand added;
  - pot and stacks: the chart's sizes, 100bb deep, blinds of folded seats as dead money;
  - the line: each street's decisions, with the opponent's bets sized from the price line;
  - bet sizes: 33% / 75% / all-in, raises 60% / all-in (the bot's 50% maps to the nearest).
Each decision then gets two numbers:
  GTO loss      best action's EV minus the chosen action's EV against an equilibrium opponent
  exploit loss  the same after locking the opponent to his HUD stats (30+ showdowns) and re-solving
The exploit number is the one that matches how the bot is meant to play (several rules exploit
play-money tendencies, which an equilibrium grades as small mistakes). Both are estimates: real
stacks, unusual preflop lines and multiway pots aren't modelled, and those hands are skipped.

--compare puts a bb value on a strategy change: for decisions where two bench --all runs (e.g. the
default and a variant) chose differently, it reads both actions' EVs from the latest grade.
"""
import argparse, glob, json, os, re, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from common import action_of  # noqa: E402

ENGINE = os.path.join(ROOT, "engine")
GRADER = os.environ.get("GTOPEN_GRADE", os.path.expanduser("~/dev/third_party/GTOpen/target/release/examples/grade_hand"))
CHARTS = json.load(open(os.path.join(ROOT, "preflop_charts.json")))
RESULTS = os.path.join(ROOT, "grade", "results")
SUIT = {"♠": "s", "♥": "h", "♦": "d", "♣": "c"}
POSTFLOP_ORDER = ["SB", "BB", "UTG", "HJ", "CO", "BTN"]
BLINDS = {"SB": 0.5, "BB": 1.0}
STREETS = ["flop", "turn", "river"]
# Two stages keep memory small (full flop trees once used 47 GB): a coarse solve from the flop with
# one bet size plus all-in (~0.85 GB, ~40-90s) grades flop decisions and gives each player's range at
# the start of every later street on the line played; each turn and river decision is then re-solved
# from its street with the bot's real sizes (33/75, raises 60), in seconds. There's no standalone
# all-in option (bets that commit most of a stack still become all-in): the stats lock applies a
# fold-to-c-bet rate to every bet, so a free shove looked hugely profitable against it.
COARSE = {"bet": [{"PotPct": 50}], "raise": [], "donk": []}
FINE = {"bet": [{"PotPct": 33}, {"PotPct": 75}], "raise": [{"PotPct": 60}], "donk": []}
EARLY, RIVER = COARSE, FINE
MEM_CAP_GB = float(os.environ.get("GRADE_MEM_GB", "6"))   # a solve above this is killed
TIMEOUT = float(os.environ.get("GRADE_TIMEOUT", "900"))


def card(c):
    return c[:-1] + SUIT[c[-1]]


def chart(players, key):
    return CHARTS[str(players)].get(key)


def weights(players, key, kinds, at_least=None):
    """hand class -> summed frequency of the actions whose label starts with one of `kinds`."""
    spot = chart(players, key)
    if not spot:
        return None
    idx = [i for i, a in enumerate(spot["actions"]) if a.split()[0] in kinds]
    out = {}
    for h, f in spot["hands"].items():
        w = sum(f[i] for i in idx)
        if at_least is not None and w >= at_least:
            w = 1.0
        out[h] = w
    return out


def size(players, key, kind):
    """The size (in bb) a chart action is made to, e.g. an open's 2.5 or a 3-bet's 7.5."""
    spot = chart(players, key)
    for a in spot["actions"]:
        if a.split()[0] == kind:
            return float(a.split()[1])
    return None


def range_text(w, extra_combo):
    toks = [f"{h}:{min(1.0, round(v, 3))}" for h, v in sorted(w.items()) if v >= 0.005]
    toks.append(f"{extra_combo}:1")            # the bot's actual hand is always in its range
    return ",".join(toks)


def read_txt(path):
    text = open(path).read()
    head = {l.split(": ", 1)[0]: l.split(": ", 1)[1] for l in text.splitlines()[:4] if ": " in l}
    return text, head


def facing(context):
    m = re.search(r"Facing a raise of your bet: call ([0-9.]+) into a pot of ([0-9.]+)", context)
    if m:
        return ("raise", float(m.group(1)), float(m.group(2)))
    m = re.search(r"Facing a bet: call ([0-9.]+) into a pot of ([0-9.]+).*?about ([0-9]+)% of the pot", context)
    if m:
        return ("bet", float(m.group(1)), float(m.group(2)), int(m.group(3)))
    return None


def villain_profile(context):
    """PostflopStats from the opponent's stats line (only with 30+ showdowns)."""
    m = re.search(r"Opponent stats[^:]*: (.*?)\.$", context)
    if not m:
        return None, None
    entries = m.group(1).split("; ")
    if len(entries) != 1:
        return None, None
    e = entries[0]
    name = e.split(":")[0]
    def stat(label):
        x = re.search(rf"{label} ([0-9]+)", e)
        return float(x.group(1)) if x else None
    sd = re.search(r"\(([0-9]+) showdowns\)", e)
    if not sd or int(sd.group(1)) < 30:
        return name, None
    cbet, fcb, xr = stat("cbet"), stat("fold to cbet"), stat("check-raise")
    if cbet is None or fcb is None:
        return name, None
    return name, {"cbet": [cbet, cbet * 0.75, cbet * 0.6], "fold_to_bet": [fcb, fcb, fcb],
                  "raise_bet": xr or 8.0, "donk": 8.0, "bet_size": "min"}


def step_for(token, facing_kind):
    """The solver path step for a bot/player action token at a node."""
    if token == "fold":
        return "fold"
    if token == "call":
        return "call" if facing_kind else "check"
    if token == "max":
        return "allin"
    if token in ("33", "50", "75"):
        return f"raise:{token}" if facing_kind else f"bet:{token}"
    if token == "raise":
        return "raise:60" if facing_kind else "bet:33"
    return None


def taken_actions(run):
    """In shadow runs the line continued with your action, not the bot's."""
    path = os.path.join(run, "shadow.tsv")
    if not os.path.exists(path):
        return {}
    out = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 3 and f[0] == "you" and not f[2].startswith("pre "):
            a = f[2].split()
            out.setdefault(f[1], a[0] if a[0] in ("33", "50", "75", "max") else a[-1])
    return out


def build_hand(run, hand):
    """The solver input for one hand, or (None, reason)."""
    pre = sorted(glob.glob(os.path.join(run, f"{hand}_preflop_turn*.txt")))
    post = sorted(glob.glob(os.path.join(run, f"{hand}_*_turn*.txt")),
                  key=lambda p: (STREETS.index(p.split("_")[-2]) if p.split("_")[-2] in STREETS else -1, p))
    post = [p for p in post if p.split("_")[-2] in STREETS]
    if not pre or not post:
        return None, "no postflop decisions"
    charts = []
    for p in pre:
        text, head = read_txt(p)
        if "chart" not in head:
            return None, "preflop not from the charts"
        m = re.match(r"(\S+) (\d)-handed, \S+: .* -> (\w+)", head["chart"])
        key, players, kind = m.group(1), int(m.group(2)), m.group(3)
        shifted = re.search(r"playing (\S+) as (\S+)", head.get("read", ""))
        if shifted:
            key = shifted.group(1)          # the opener's real position, for his range
        charts.append((key, players, kind))
    inhand = json.loads(subprocess.run([ENGINE, "--in-hand", pre[0][:-4] + ".png", post[0][:-4] + ".png"],
                                       capture_output=True, text=True).stdout or "{}")
    if len(inhand.get("in_hand", [])) != 1:
        return None, "multiway or unreadable seats"
    hero, vil, players = inhand["hero"], inhand["in_hand"][0], charts[0][1]
    key1, _, kind1 = charts[0]
    parts = key1.split(":")
    if parts[0] == "RFI" and kind1 == "raise":
        open_to = size(players, key1, "raise")
        if len(charts) == 1:
            hero_w = weights(players, key1, ["raise"], at_least=0.15)
            vil_w = weights(players, f"VO:{vil}:{hero}", ["call"])
            put, aggressor = open_to, "hero"
        elif len(charts) == 2 and charts[1][0] == f"V3:{hero}:{vil}" and charts[1][2] == "call":
            rfi = weights(players, key1, ["raise"], at_least=0.15)
            v3 = weights(players, charts[1][0], ["call"])
            hero_w = {h: rfi[h] * v3.get(h, 0) for h in rfi}
            vil_w = weights(players, f"VO:{vil}:{hero}", ["raise"])
            put, aggressor = size(players, f"VO:{vil}:{hero}", "raise"), "villain"
        else:
            return None, "4-bet or other preflop line"
    elif parts[0] == "VO" and len(charts) == 1 and parts[2] == vil:
        if kind1 == "call":
            hero_w = weights(players, key1, ["call"])
            vil_w = weights(players, f"RFI:{vil}", ["raise"], at_least=0.15)
            put, aggressor = size(players, f"RFI:{vil}", "raise"), "villain"
        elif kind1 == "raise":
            # the small blind 3-bets everything the chart calls with
            hero_w = weights(players, key1, ["raise", "call"] if hero == "SB" else ["raise"])
            rfi = weights(players, f"RFI:{vil}", ["raise"], at_least=0.15)
            v3 = weights(players, f"V3:{vil}:{hero}", ["call"]) or {}
            vil_w = {h: rfi[h] * v3.get(h, 0) for h in rfi}
            put, aggressor = size(players, key1, "raise"), "hero"
        else:
            return None, "preflop jam"
    else:
        return None, "preflop line not covered"
    if not hero_w or not vil_w or put is None:
        return None, "chart missing"
    dead = sum(b for p, b in BLINDS.items() if p not in (hero, vil) and players > 2)
    pot, stack = 2 * put + dead, 100 - put
    order = POSTFLOP_ORDER if players > 2 else ["BB", "SB"]
    hero_oop = order.index(hero) < order.index(vil)

    taken = taken_actions(run)
    recs = []
    for p in post:
        text, head = read_txt(p)
        ctx = head.get("cards", "")
        tag = os.path.basename(p)[:-4]
        bot = action_of(text)
        if bot is None or "Your cards:" not in ctx:
            return None, "unreadable decision"
        recs.append({"tag": tag, "street": tag.split("_")[1], "ctx": ctx, "bot": bot,
                     "took": taken.get(tag, bot), "facing": facing(ctx)})
    hole = re.search(r"Your cards: (\S+) (\S+)", recs[0]["ctx"])
    combo = card(hole.group(1)) + card(hole.group(2))
    board = re.search(r"Board: ([^.]+)\.", recs[-1]["ctx"]).group(1).split()
    board = [card(c) for c in board]
    vname, profile = villain_profile(recs[0]["ctx"])

    # the line, street by street; one query per bot decision
    queries, path = [], []
    for si, street in enumerate(STREETS):
        rs = [r for r in recs if r["street"] == street]
        if not rs:
            if si > 0 and any(r["street"] in STREETS[si:] for r in recs):
                return None, "a street without a decision"
            break
        if si > 0:
            path.append("card:" + board[2 + si])
        prev = None
        for r in rs:
            f = r["facing"]
            if prev is None:
                if not hero_oop:
                    path.append(f"bet:{f[3]}" if f and f[0] == "bet" else "check")
                elif f:
                    return None, "facing a bet before acting first"
            else:
                if f and f[0] == "raise":
                    path.append("raise:60")
                elif f and f[0] == "bet":
                    path.append(f"bet:{f[3]}")
                else:
                    return None, "second decision on a street without a bet"
            chosen = step_for(r["bot"], f)
            if chosen is None:
                return None, "unknown action"
            queries.append({"id": r["tag"], "path": list(path), "combo": combo, "chosen": chosen})
            took = step_for(r["took"], f)
            path.append(took)
            prev = took
            if took == "fold":
                break
        if prev == "fold":
            break
        # how the street closed
        later = [r for r in recs if STREETS.index(r["street"]) > si]
        if prev.startswith(("bet", "raise", "allin")):
            if not later:
                break                                  # the opponent folded
            path.append("call")
        elif prev == "check":
            if hero_oop:
                path.append("check")                   # checked back
        if prev == "allin":
            break
    hero_idx = 0 if hero_oop else 1
    config = {"board": "".join(board[:3]),
              "range_oop": range_text(hero_w if hero_oop else vil_w, combo if hero_oop else "XX"),
              "range_ip": range_text(vil_w if hero_oop else hero_w, "XX" if hero_oop else combo),
              "tree": {"starting_pot": pot, "effective_stack": stack, "rake_pct": 0, "rake_cap": 0,
                       "oop": [COARSE] * 3, "ip": [COARSE] * 3,
                       "allin_threshold": 0.85, "add_allin": False, "max_raises": 3}}
    for k in ("range_oop", "range_ip"):
        config[k] = config[k].replace(",XX:1", "")
    return {"config": config, "villain": 1 - hero_idx,
            "pf_aggressor": hero_idx if aggressor == "hero" else 1 - hero_idx,
            "profile": profile, "queries": queries,
            "meta": {"run": os.path.basename(run), "hand": hand, "hero": hero, "villain": vil, "villain_name": vname,
                     "combo": combo, "board": board, "pot": pot, "bot": {r["tag"]: r["bot"] for r in recs}}}, None


def solve(hand, iterations):
    inp = {k: v for k, v in hand.items() if k != "meta"}
    inp["iterations"] = iterations
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(inp, f)
    t0 = time.time()
    out_f = tempfile.TemporaryFile("w+")
    p = subprocess.Popen([GRADER, f.name], stdout=out_f, stderr=subprocess.PIPE, text=True)
    peak, killed = 0.0, None
    while p.poll() is None:                    # watchdog: memory and time
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
        gb = int(rss) / 1048576 if rss.isdigit() else 0.0
        peak = max(peak, gb)
        if gb > MEM_CAP_GB or time.time() - t0 > TIMEOUT:
            killed = f"over {MEM_CAP_GB:g} GB" if gb > MEM_CAP_GB else f"over {TIMEOUT:.0f}s"
            p.kill()
            p.wait()
            break
        time.sleep(0.2)
    os.remove(f.name)
    secs = time.time() - t0
    if killed:
        return {"error": f"stopped: {killed}", "peak_gb": peak, "secs": secs}
    if p.returncode != 0:
        return {"error": (p.stderr.read() or "solver failed").strip().splitlines()[-1], "peak_gb": peak, "secs": secs}
    out_f.seek(0)
    out = json.loads(out_f.read())
    out["secs"], out["peak_gb"] = secs, peak
    return out


def with_combo(rng, combo):
    """A range text that surely holds the bot's hand (with a small weight if the solve gave it none)."""
    rev = combo[2:] + combo[:2]
    if any(t.split(":")[0] in (combo, rev) for t in rng.split(",") if t):
        return rng
    return (rng + "," if rng else "") + f"{combo}:0.05"


def solve_hand(hand, iterations):
    """Stage 1 from the flop (flop decisions, plus ranges at each later street), stage 2 per street."""
    queries, combo, cfg = hand["queries"], hand["meta"]["combo"], hand["config"]
    hero_oop = hand["villain"] == 1
    def street_of(q):
        return sum(1 for st in q["path"] if st.startswith("card:"))      # 0 flop, 1 turn, 2 river
    exports = {}
    for q in queries:
        k = street_of(q)
        if k and k not in exports:
            cut = max(i for i, st in enumerate(q["path"]) if st.startswith("card:")) + 1
            exports[k] = q["path"][:cut]
    stage1 = dict(hand, queries=[q for q in queries if street_of(q) == 0],
                  exports=[{"id": str(k), "path": p} for k, p in exports.items()], max_gb=MEM_CAP_GB / 2)
    out1 = solve(stage1, iterations)
    if "error" in out1:
        return out1
    answers = {q["id"]: r for q, r in zip(stage1["queries"], out1["results"])}
    secs, peak = out1["secs"], out1["peak_gb"]
    pot0, eff0 = cfg["tree"]["starting_pot"], cfg["tree"]["effective_stack"]
    for x in out1.get("exports", []):
        k = int(x["id"])
        street_qs = [dict(q, path=q["path"][len(exports[k]):]) for q in queries if street_of(q) == k]
        for which in ("gto", "exploit"):
            e = x.get(which)
            if not e or "error" in e or (which == "exploit" and not hand.get("profile")):
                continue
            sub = {"config": {"board": "".join(e["board"]),
                              "range_oop": with_combo(e["oop"], combo) if hero_oop else e["oop"],
                              "range_ip": e["ip"] if hero_oop else with_combo(e["ip"], combo),
                              "tree": dict(cfg["tree"], starting_pot=e["pot"], effective_stack=eff0 + pot0 / 2 - e["put"][0],
                                           oop=[FINE] * 3, ip=[FINE] * 3)},
                   "villain": hand["villain"], "pf_aggressor": hand["pf_aggressor"],
                   "profile": hand.get("profile") if which == "exploit" else None,
                   "queries": street_qs, "max_gb": MEM_CAP_GB / 2}
            out2 = solve(sub, iterations)
            secs += out2.get("secs", 0)
            peak = max(peak, out2.get("peak_gb", 0))
            for q, r in zip(street_qs, out2.get("results", [])):
                answers.setdefault(q["id"], {})[which] = r.get(which) if which == "exploit" else r.get("gto")
            if "error" in out2:
                for q in street_qs:
                    answers.setdefault(q["id"], {})[which] = {"error": out2["error"]}
    return {"results": [answers.get(q["id"], {"gto": {"error": "not solved"}}) for q in queries],
            "secs": secs, "peak_gb": peak}


def loss(node):
    if not node or "error" in node:
        return None
    evs = [e for e in node["evs"] if e is not None]
    if not evs or node["evs"][node["chosen"]] is None:
        return None
    return max(evs) - node["evs"][node["chosen"]]


def grade(runs, iterations, jobs, only=None, dry=False):
    hands, skipped = [], {}
    for run in runs:
        for hand in sorted({os.path.basename(p)[:4] for p in glob.glob(os.path.join(run, "h*_turn*.txt"))}):
            if only and hand != only:
                continue
            h, why = build_hand(run, hand)
            if h:
                hands.append(h)
            else:
                skipped[why] = skipped.get(why, 0) + 1
    print(f"{len(hands)} heads-up hands to solve; skipped: " + (", ".join(f"{v} {k}" for k, v in sorted(skipped.items(), key=lambda x: -x[1])) or "none"))
    if dry:
        for h in hands:
            m = h["meta"]
            print(f"  {m['run']}/{m['hand']}: {m['combo']} {m['hero']} vs {m['villain']}, pot {m['pot']:g}bb, "
                  f"{len(h['queries'])} decisions, stats {'yes' if h['profile'] else 'no'}")
        return
    rows = []
    with ThreadPoolExecutor(jobs) as pool:
        for h, out in zip(hands, pool.map(lambda h: solve_hand(h, iterations), hands)):
            m = h["meta"]
            if "error" in out:
                print(f"  {m['run']}/{m['hand']}: solver error: {out['error']} (peak {out.get('peak_gb', 0):.1f} GB, {out.get('secs', 0):.0f}s)")
                continue
            for q, r in zip(h["queries"], out["results"]):
                g, e = r.get("gto"), r.get("exploit")
                if not g or "error" in g:
                    print(f"  {m['run']}/{q['id']}: {g.get('error') if g else 'no answer'}")
                    continue
                best = g["actions"][max(range(len(g["evs"])), key=lambda i: g["evs"][i] if g["evs"][i] is not None else -1e9)]
                rows.append({"id": f"{m['run']}/{q['id']}", "combo": m["combo"], "board": m["board"], "vs": m["villain_name"],
                             "chosen": g["actions"][g["chosen"]], "gto_best": best, "gto_loss": loss(g),
                             "exploit_loss": loss(e), "gto": g, "exploit": e, "secs": out.get("secs")})
            print(f"  {m['run']}/{m['hand']} {m['combo']} {m['hero']} vs {m['villain']}: {len(h['queries'])} decisions, "
                  f"{out.get('secs', 0):.0f}s, peak {out.get('peak_gb', 0):.1f} GB")
    if not rows:
        print("nothing graded")
        return
    gl = [r["gto_loss"] for r in rows if r["gto_loss"] is not None]
    el = [r["exploit_loss"] for r in rows if r["exploit_loss"] is not None]
    print(f"\n{len(rows)} decisions graded")
    print(f"  GTO loss:     {sum(gl) / len(gl):.2f} bb per decision, {sum(gl):.1f} bb total")
    if el:
        print(f"  exploit loss: {sum(el) / len(el):.2f} bb per decision, {sum(el):.1f} bb total ({len(el)} decisions with opponent stats)")
    print("\nLargest losses:")
    for r in sorted(rows, key=lambda r: -(r["exploit_loss"] if r["exploit_loss"] is not None else r["gto_loss"]))[:10]:
        ex = f", exploit {r['exploit_loss']:.2f}" if r["exploit_loss"] is not None else ""
        print(f"  {r['id']}: {r['combo']} on {' '.join(r['board'])}: chose {r['chosen']}, solver {r['gto_best']} "
              f"(GTO loss {r['gto_loss']:.2f}{ex} bb)")
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, time.strftime("%Y%m%d_%H%M%S") + ".json")
    json.dump({"runs": runs, "rows": rows, "skipped": skipped}, open(path, "w"), indent=1)
    print(f"\nsaved {os.path.relpath(path, ROOT)}")


def compare(a_path, b_path):
    """For decisions where two bench --all runs differ, the EV of each choice from the latest grade."""
    graded = sorted(glob.glob(os.path.join(RESULTS, "*.json")))
    if not graded:
        sys.exit("run a grade first")
    rows = {r["id"]: r for r in json.load(open(graded[-1]))["rows"]}
    a, b = (json.load(open(p)) for p in (a_path, b_path))
    ra = {r["id"]: r for r in a["rows"]}
    rb = {r["id"]: r for r in b["rows"]}
    total = {"gto": 0.0, "exploit": 0.0}
    n = 0
    for i in ra:
        if i not in rb or ra[i]["now"] == rb[i]["now"] or i not in rows:
            continue
        row = rows[i]
        line = f"- {i}: {ra[i]['now']} -> {rb[i]['now']}"
        for which in ("gto", "exploit"):
            node = row.get(which)
            if not node or "error" in node:
                continue
            facing_kind = any(l.lower().startswith(("call", "fold")) for l in node["actions"])
            def ev(tok):
                step = step_for(tok, facing_kind)
                labels = [l.lower() for l in node["actions"]]
                for j, l in enumerate(labels):
                    if step in ("check", "call", "fold") and l.startswith(step) or step == "allin" and l.startswith("all-in"):
                        return node["evs"][j]
                if step and ":" in step:
                    kind, pct = step.split(":")
                    cands = [(abs(float(re.search(r"\(([0-9.]+)%\)", l).group(1)) - float(pct)), j)
                             for j, l in enumerate(labels) if l.startswith(kind) and "(" in l]
                    if cands:
                        return node["evs"][min(cands)[1]]
                return None
            x, y = ev(ra[i]["now"]), ev(rb[i]["now"])
            if x is not None and y is not None:
                line += f"   {which} {y - x:+.2f} bb"
                total[which] += y - x
        n += 1
        print(line)
    print(f"\n{n} graded decisions differ: change worth {total['gto']:+.2f} bb against GTO, {total['exploit']:+.2f} bb against the opponents' stats")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="*")
    ap.add_argument("--iterations", type=int, default=400)
    ap.add_argument("--jobs", type=int, default=1, help="solves at once (each can take GBs)")
    ap.add_argument("--hand", help="grade only this hand, e.g. h012")
    ap.add_argument("--dry-run", action="store_true", help="list the gradeable hands without solving")
    ap.add_argument("--compare", nargs=2, metavar=("A_JSON", "B_JSON"))
    a = ap.parse_args()
    if a.compare:
        compare(*a.compare)
    elif a.runs:
        grade(a.runs, a.iterations, a.jobs, a.hand, a.dry_run)
    else:
        ap.print_help()
