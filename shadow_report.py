#!/usr/bin/env python3
"""Compares your play with the bot's from shadow-mode runs (pokerbot shadow).

Usage: shadow_report.py <run-dir>... [--all]

Each run folder's shadow.tsv has "bot<TAB>tag<TAB>action" and "you<TAB>tag<TAB>action" lines, where tag
is the turn's screenshot name (h012_flop_turn) and action is fold, call (check or call), raise, or a
sizing preset then raise ("75 raise"). Prints how often you agreed, where you didn't (with the cards and
the bot's reason), and both styles side by side. --all lists agreements too.
"""
import os, re, sys
from collections import Counter, defaultdict

def kind(action):
    a = action.split()
    if not a: return "?"
    if a[-1] in ("fold", "xf"): return "fold"
    if a[-1] in ("call", "callany"): return "call"
    if a[-1] == "raise" or a[0] in ("33", "50", "75", "max"): return "raise"
    return a[-1]

def size(action):
    a = action.split()
    return a[0] if len(a) > 1 else ""

def context(run, tag):
    """The cards line and the bot's reason from the turn's .txt file."""
    try:
        text = open(os.path.join(run, tag + ".txt")).read()
    except OSError:
        return "", ""
    cards = next((l[7:] for l in text.splitlines() if l.startswith("cards: ")), "")
    if text.startswith("chart:"):
        return cards, text.splitlines()[0]
    body = [l for l in text.split("\n\n", 1)[-1].splitlines() if l.strip()]
    return cards, " ".join(body[:-1])

def street(tag):
    m = re.match(r"h\d{3}_(\w+?)_turn", tag)
    return m.group(1) if m else "pre-move"

def main(args):
    show_all = "--all" in args
    runs = [a for a in args if a != "--all"]
    if not runs:
        print(__doc__); return
    rows = []           # (run, tag, bot, you)
    premoves = Counter()
    for run in runs:
        path = os.path.join(run, "shadow.tsv")
        if not os.path.exists(path):
            print(f"{run}: no shadow.tsv"); continue
        bot, you = {}, {}
        for line in open(path):
            f = line.rstrip("\n").split("\t")
            if len(f) < 3: continue
            who, tag, action = f[:3]
            if who == "bot": bot[tag] = action
            elif who == "you":
                if action.startswith("pre "): premoves[action[4:]] += 1
                else: you.setdefault(tag, action)    # your first click on that turn
        for tag in sorted(set(bot) & set(you)):
            rows.append((run, tag, bot[tag], you[tag]))
        only_you = sorted(set(you) - set(bot))
        if only_you:
            print(f"{os.path.basename(run)}: {len(only_you)} of your actions had no bot answer (it was still thinking or the turn wasn't caught)")
    if not rows:
        print("no decisions with both a bot answer and your click yet"); return

    same = [r for r in rows if kind(r[2]) == kind(r[3])]
    print(f"\n{len(rows)} decisions compared: you agreed with the bot on {len(same)} ({100 * len(same) // len(rows)}%)")
    by_street = defaultdict(lambda: [0, 0])
    for r in rows:
        s = by_street[street(r[1])]; s[0] += 1; s[1] += kind(r[2]) == kind(r[3])
    print("  " + ", ".join(f"{k} {v[1]}/{v[0]}" for k, v in sorted(by_street.items(), key=lambda x: ["preflop", "flop", "turn", "river"].index(x[0]) if x[0] in ["preflop", "flop", "turn", "river"] else 9)))

    # style: what each side did, preflop (first decision of the hand) and postflop
    def style(pick):
        pre = Counter(kind(pick(r)) for r in rows if r[1].endswith("_preflop_turn"))
        post = Counter(kind(pick(r)) for r in rows if street(r[1]) in ("flop", "turn", "river"))
        n_pre, n_post = sum(pre.values()) or 1, sum(post.values()) or 1
        aggr = post["raise"] / ((post["raise"] + post["call"]) or 1)
        return (f"preflop raise {100 * pre['raise'] // n_pre}% / call {100 * pre['call'] // n_pre}% / fold {100 * pre['fold'] // n_pre}%"
                f" (of {sum(pre.values())});  postflop bet-or-raise {100 * post['raise'] // n_post}% / check-or-call {100 * post['call'] // n_post}%"
                f" / fold {100 * post['fold'] // n_post}% (of {sum(post.values())}), aggression {aggr:.0%}")
    print("\nYou: " + style(lambda r: r[3]))
    print("Bot: " + style(lambda r: r[2]))
    if premoves:
        print("Your pre-move clicks: " + ", ".join(f"{k} {v}" for k, v in premoves.most_common()))

    print("\nDisagreements:" if not show_all else "\nAll decisions:")
    for run, tag, b, y in rows:
        if not show_all and kind(b) == kind(y): continue
        cards, reason = context(run, tag)
        print(f"- {tag}: bot {b}, you {y}" + ("" if kind(b) != kind(y) else "  (same)"))
        if cards: print(f"    {cards}")
        if reason: print(f"    bot: {reason}")

if __name__ == "__main__":
    main(sys.argv[1:])
