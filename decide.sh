#!/bin/sh
# The decider for the engine: the strategy prompt lives here; decide.py sends it to the model.
# Usage: decide.sh <screenshot.png> <turn|premove> [context]   one decision
#        decide.sh --session                                   one hand, kept in one conversation
# [context] is what the engine read off the table (cards, hand strength, the price of a call, stats).
# Prints a one-line reason, then the action word on the last line.
#
# POKER_BACKEND: claude-cli (default, your Claude login), anthropic (API key), openai (any
#   OpenAI-compatible endpoint, e.g. Ollama or LM Studio, with POKER_BASE_URL) - see decide.py.
# POKER_MODEL (opus by default; sonnet, haiku, or the backend's model name), POKER_EFFORT (low).
# POKER_PROMPT=<file> sources a strategy variant that can change any POKER_* line below.

POKER_BASE="6-max NLHE, play money. You are bottom center (face-up cards). D marks the button; preflop order is UTG, HJ, CO, BTN, SB, BB. Chips in front of a seat are its bet this street. The hand label under your name counts board pairs; judge only what your hole cards add. Play loose-aggressive: bet and raise rather than call; preflop, raise or fold when first in, never limp, and isolate limpers with raises. Opponents are play-money players: a turn or river bet of 75% pot or more is almost always strong, so fold no pair and any pair below top pair to it. Against half pot or less you need only 25%: call with any pair, especially after the bettor checked earlier streets. Size value bets by the opponent: with top pair good kicker or better, bet 75 against callers (fold to c-bet 30% or less, or loose unknowns), 33 or check against folders (fold to c-bet 40%+). With weaker hands and draws, heads-up as the preflop raiser c-bet small (33) most flops, more against players who fold to c-bets 35%+; when checked to on the turn, bet draws against fold-prone opponents. No big river bluffs. On the river when checked to, bet small (33) for thin value with second pair or weak top pair whenever worse hands can call, e.g. after the opponent gave up (checked back the turn, or c-bet then checked); stronger hands keep the value sizing above. Check instead when almost nothing worse calls, e.g. a pair below two board cards on a high or paired board. A raise of your bet is usually two pair or better: fold one pair below top pair to it, unless the raiser's stats show a loose, aggressive player. Opponent stats, when given with enough showdowns, override these defaults: against a player who wins under 45% of showdowns (WSD) over 300+ showdowns, call those turn/river bets with second pair or better. Preflop outside the BB, call a raise only with a pair or suited broadway cards; 3-bet strong hands and suited aces, more against players who fold to 3-bets 50%+; otherwise fold."
POKER_TURN="Your turn. Action: fold, call (or check), raise (min), or one of the four sizing buttons above Raise, named as labeled: 33/50/75/max (% of pot; Max is all-in) or, preflop before anyone raises, 2x/2.5x/3x/4x (raise to that many big blinds)."
POKER_PRE="Not your turn yet. Pre-move: xf (hands you would fold to a bet), check (check if free, else decide later), none (hands worth playing: decide on your turn). Answer only xf, check or none."
POKER_REPLY="Reply with one reason of at most 15 words, then the action alone on the last line."
POKER_MODEL="${POKER_MODEL:-opus}"
POKER_EFFORT="${POKER_EFFORT:-low}"
# POKER_PROMPT=<file> sources a strategy variant (it can change any POKER_* line), e.g. for bench/run.py.
if [ -n "$POKER_PROMPT" ]; then . "$POKER_PROMPT"; fi
export POKER_BASE POKER_TURN POKER_PRE POKER_REPLY POKER_MODEL POKER_EFFORT

exec python3 "$(dirname "$0")/decide.py" "$@"
