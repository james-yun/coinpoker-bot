"""Shared bits of the replay benchmark: running the decider on a saved spot and reading its action."""
import os, re, signal, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench")
DECIDE = os.path.join(ROOT, "decide.sh")

ACTIONS = {"fold", "call", "raise", "33", "50", "75", "max", "2x", "25x", "3x", "4x"}
ALIASES = {"check": "call", "bet": "raise", "min": "raise", "allin": "max", "shove": "max",
           "x/f": "fold", "xf": "fold", "checkfold": "fold"}
# groups an expectation can name instead of single actions
GROUPS = {
    "bet": {"raise", "33", "50", "75", "max", "2x", "25x", "3x", "4x"},   # any bet or raise
    "big": {"75", "max"},                                                # a big bet
    "value": {"50", "75", "max"},                                        # half pot or more
    "small": {"33", "raise"},                                            # a small bet
}


def action_of(text):
    """The action the decider named on its last line, as a token like 'call' or '75' (None if none)."""
    lines = [l for l in (text or "").splitlines() if l.strip()]
    if not lines:
        return None
    def norm(s):
        t = re.sub(r"[^a-z0-9/]", "", s.lower())
        return ALIASES.get(t, t)
    t = norm(lines[-1])
    if t not in ACTIONS:
        words = lines[-1].split()
        t = norm(words[-1]) if words else ""
    return t if t in ACTIONS else None


def allowed(expect):
    """The set of actions an expectation list ('call', 'value', 'fold|call', ...) accepts."""
    out = set()
    for e in expect:
        out |= GROUPS.get(e, {e})
    return out


def decide(image, context, mode="turn", variant=None, model=None, effort=None, timeout=60):
    """Runs decide.sh once on a screenshot; returns (action token, full reply, seconds)."""
    env = dict(os.environ)
    if variant:
        env["POKER_PROMPT"] = os.path.abspath(variant)
    if model:
        env["POKER_MODEL"] = model
    if effort:
        env["POKER_EFFORT"] = effort
    t0 = time.time()
    # its own process group: on a timeout the claude process decide.sh started is killed too (it holds
    # the output pipe open, so killing decide.sh alone left the benchmark waiting for minutes)
    p = subprocess.Popen([DECIDE, image, mode, context], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, env=env, start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return "timeout", "", time.time() - t0
    return action_of(out), out.strip(), time.time() - t0


ENGINE = os.path.join(ROOT, "engine")


def fresh_context(spot):
    """The context the model gets today for this spot: what preflop happened (saved), then the
    engine's current reading of the screenshot (cards, hand, price of a call, opponent stats)."""
    image = os.path.join(BENCH, spot["image"])      # (an absolute path stays as it is)
    line = subprocess.run([ENGINE, "--context", image], capture_output=True, text=True).stdout.strip()
    parts = [spot.get("prefix", ""), line, spot.get("append", "")]
    return " ".join(p for p in parts if p)


def saved_decision(txt_path):
    """(cards/context line, the action played) from a run folder's decision file, or None for chart
    decisions and pre-moves (only the model's turn decisions are replayed)."""
    try:
        text = open(txt_path).read()
    except OSError:
        return None
    if not text.startswith("mode: turn"):
        return None
    cards = next((l[7:] for l in text.splitlines() if l.startswith("cards: ")), None)
    if cards is None:
        return None
    return cards, action_of(text)
