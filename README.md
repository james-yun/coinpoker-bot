# pokerbot

![Pokerbot demo](https://github.com/user-attachments/assets/bf65fe56-c8d3-410d-a494-e8a8ca2f6e96)

An autonomous player for CoinPoker 6-max No-Limit Hold'em tables, on macOS. It watches the table window and uses player stats, GTO preflop charts and LLM (e.g. Claude Opus) postflop to decide the action. Includes replay tools that test strategy changes on hands you've already played.

For play-money tables only. Running a bot at real-money tables cheats the other players and breaks the site's rules. Use at your own risk.

## Contents

- [Install](#install)
- [Commands](#commands)
- [Configuration and models](#configuration-and-models)
- [How a decision is made](#how-a-decision-is-made)
- [Preflop charts](#preflop-charts)
- [Player stats](#player-stats)
- [Results](#results)
- [Shadow mode](#shadow-mode)
- [Testing strategies on past hands](#testing-strategies-on-past-hands)
- [Tests](#tests)
- [Project layout](#project-layout)
- [Troubleshooting and tools](#troubleshooting-and-tools)

## Install

Requirements:
- macOS 14 or later, with the Xcode command-line tools (`swiftc`).
- Python 3.
- One model backend. The default is the Claude Code CLI with your Claude login; see [Configuration and models](#configuration-and-models) for the others.

**From a release** (no Xcode tools needed): unpack `pokerbot-<version>-macos.tar.gz` and run its installer.

```
tar xzf pokerbot-<version>-macos.tar.gz
pokerbot-<version>/install.sh     # copies it to ~/.local/share/pokerbot, links ~/.local/bin/pokerbot
pokerbot test                     # optional: self-tests
```

The engine is a universal binary (Apple silicon and Intel) with an ad-hoc signature. The installer clears the quarantine flag a browser download puts on it, so Gatekeeper doesn't block it. Running `install.sh` from a newer release upgrades in place and keeps your benchmark spots. `install.sh --uninstall` removes it but leaves your config.

**From source:**

```
make install      # builds the engine from src/ and links pokerbot into ~/.local/bin
make test         # optional: self-tests
make dist         # a release: dist/pokerbot-<version>-macos.tar.gz and its .sha256
```

`make dist` builds the engine for arm64 and x86_64 at a macOS 14 target, joins the two with `lipo`, signs the result ad hoc, and packs it with the scripts, charts, card templates and tests. The version comes from `git describe`, so tag a commit (`git tag v0.1.0`) to give a release a proper name. Your benchmark spots aren't included, since their screenshots show other players.

The terminal you run it from needs **Screen Recording** (to watch the table) and **Accessibility** (to click) in System Settings → Privacy & Security. macOS asks for both the first time.

## Commands

| Command | What it does |
|---|---|
| `pokerbot play [--debug]` | Plays autonomously. `--debug` logs every state change, click point and model answer, with timestamps. |
| `pokerbot shadow [--debug]` | You play; the bot decides every spot silently and both choices are recorded. See [Shadow mode](#shadow-mode). |
| `pokerbot results [run]` | Per-hand results of a run (the latest by default). |
| `pokerbot report [run...]` | Compares your play with the bot's in shadow runs (the latest by default). |
| `pokerbot bench [...]` | Replays past decisions with a strategy variant. See [Testing strategies](#testing-strategies-on-past-hands). |
| `pokerbot tools …` | The engine's tools on saved screenshots. See [Troubleshooting and tools](#troubleshooting-and-tools). |
| `pokerbot test` | Self-tests: logic, card reader, decider. |
| `pokerbot build` | Recompiles the engine (from source only). |
| `pokerbot config` | Shows the config file and its values. |
| `pokerbot version` | The release, or the git commit when run from source. |

Flags after `play` and `shadow` go straight to the engine:
- `--front` leaves the table in front after clicking. By default your keyboard focus is handed back; see [Clicking](#clicking).
- `--manual` turns the decider off: only actions you type in the terminal are clicked.
- `--accept-cashout` accepts EV Cashout offers. By default they're rejected, which is never worse in expected value.
- `--no-session` makes every decision a separate model call, instead of one conversation per hand.
- `--decide <cmd>` uses a different decider command.

Each run saves into its own folder, `<output_dir>/<date>_<time>/`:
- **Screenshots** for every decision: `h007_flop_turn.png` is hand 7, on the flop. A second decision on the same street gets `_turn2`.
- **Decision files** beside them, `.txt`: the context the model got and its full answer (or the chart's play).
- **`results.txt`:** one RESULT line per hand.
- **`shadow.tsv`:** shadow-mode runs only.

`cur.png` in the output folder is the latest capture, refreshed about every 0.7s.

## Configuration and models

`~/.config/pokerbot/config.toml` is created on first run:

```toml
backend = "claude-cli"      # claude-cli | anthropic | openai
model = "opus"              # opus / sonnet / haiku for Claude, or the endpoint's model name
effort = "low"              # Claude's thinking effort: low, medium, high
base_url = ""               # openai backend: e.g. "http://localhost:11434/v1" (Ollama), LM Studio, vLLM
api_key_env = ""            # the environment variable holding the key (default ANTHROPIC_API_KEY / OPENAI_API_KEY)
output_dir = "/tmp/poker"
prompt = ""                 # a strategy variant, e.g. "prompts/no-floats.sh"
```

Environment variables (`POKER_BACKEND`, `POKER_MODEL`, `POKER_EFFORT`, `POKER_BASE_URL`, `POKER_API_KEY_ENV`, `POKER_PROMPT`) override the file.

**Backends** (`decide.py`):
- **`claude-cli`** (the default) runs the Claude Code CLI with your Claude login, so no API key is needed. Each hand gets one CLI process, started when the cards are dealt so its startup is hidden. Opus at low effort answers in about 1–3s.
- **`anthropic`** calls the Anthropic API through the official SDK: run `pip install anthropic` and set `ANTHROPIC_API_KEY`. The strategy prompt is a cached system prompt, effort is set from the config, and a refused request is re-run on a fallback model chosen by the API.
- **`openai`** works with any OpenAI-compatible chat endpoint that accepts images: OpenAI, Ollama, LM Studio or vLLM. Set `base_url`. Local servers need no key.

Higher effort didn't produce better decisions in replays and added 0.5–1.5s per decision, so low is the default. To compare backends or models on your own hands, use `pokerbot bench --backend openai --base-url http://localhost:11434/v1 --model <name>`.

## How a decision is made

1. **Seeing the turn.** The engine streams the table window with ScreenCaptureKit (about 50ms reaction) and waits for the red Fold button. It always captures at 2x, scaled to fit, so a window on a non-Retina display reads the same way. It ignores the stats window, waits for board cards to finish dealing, and clicks OPEN when cards arrive under the squeeze overlay.
2. **Reading the table.**
   - **Cards:** your hole cards and the board come from glyph templates (`cards.txt`).
   - **Hand:** your exact hand and draws, e.g. "second pair (Qs, J kicker). Draws: none."
   - **Price:** when facing a bet, the Call amount and the pot, e.g. "call 0.29 into a pot of 0.68… you need 30% equity; the bet is about 74% of the pot". When your own bet was raised, it says so.
   - **Opponents:** the stats of the players still in the hand.
   - **Text recognition:** amounts are read with macOS text recognition, which treats a letter O next to a digit as a zero.
3. **Deciding.**
   - **Preflop** spots the charts cover are played from the charts, instantly.
   - **Everything else** goes to the model, along with the screenshot and the context above. The prompt is in `decide.sh` and asks for a one-line reason, then the action. Within a hand it's one conversation, so the model remembers the earlier streets. Postflop it's also told what happened preflop.
4. **Clicking.** The action is clicked: a sizing preset (33/50/75/Max, or 2X–4X before anyone raises) and then Raise. Answers are fitted to the buttons actually on screen. When 33% is greyed out in a tiny pot, the other presets are still used.

### Clicking

The table is a Unity window. It ignores clicks posted straight to its process and has no Accessibility buttons, so clicks must be real mouse clicks:
- **Cursor:** it goes back where it was.
- **Keyboard focus:** it's handed back to the app you were using, about 0.2s after each action. Keys typed in that moment go to the table.
- **A covered table:** it's raised for the click.
- **A moving window:** clicks are skipped.
- **`--front`:** keeps the table in front instead of handing focus back.

## Preflop charts

`preflop_charts.json` holds GTOpen preflop solves (100bb, no rake, 2.5bb opens, 3x re-raises), one per table size from 2 to 6 players. It covers three kinds of spot:
- folded to you (`RFI:<pos>`);
- facing one open with no callers (`VO:<you>:<opener>`);
- facing a 3-bet after you opened (`V3:<you>:<3-bettor>`).

Your position comes from the D button and the seats dealt in. The action comes from each seat's tag color: blinds blue, call/check green, raise orange, all-in red, fold dark. The tag read is cross-checked against which sizing buttons are on screen.

Adjustments:
- **Mixed spots lean aggressive.** The raise is taken whenever the chart raises at least 15% of the time; otherwise the play is sampled by frequency.
- **Small blind facing a raise: 3-bet or fold.** A chart call becomes a 3-bet.
- **Loose or tight openers** (30+ showdowns). Against a loose opener (PFR 26+ or steal 45+), it plays the chart for an opener one seat later, up to the button. Against a tight one (PFR 14 or less and steal 25 or less), one seat earlier.
- **Light 3-bets** against openers who fold to 3-bets 55% or more: any raise in the mix, 5% or more, is taken.

Each chart decision logs a line such as `CHART (h004_preflop_turn): RFI:BTN 3-handed, KJo: raise 100% -> raise`. Spots the charts don't cover go to the model: limped pots, raise plus callers, and all-ins.

## Player stats

Clicking a seat's name plate opens the client's stats window. Whenever it isn't your turn, starting right at launch, the engine does this for each seated player:
1. Reads the Game Stats tab: VPIP, PFR, 3-bet, fold to 3-bet, c-bet, fold to c-bet, steal, check-raise, WTSD, WSD.
2. Reads the Showdown tab's showdown count, which gives the sample size. It's taken only after clicking that tab, because the count shown on a fresh open can belong to the previous player.
3. Closes the window.

Each player is read once and saved to `players.tsv` in the output folder for a day. Names are matched without case, punctuation or lookalike letters, and the table's truncated names still match.

The model gets one line per opponent still in the hand, marked "rough" under 30 showdowns. The scanner's clicks never overlap the action clicks. If the stats window is open when you act, the table is brought forward first.

## Results

At your first preflop decision of each hand, the engine reads your stack and the pot, then prints the previous hand's result:

```
RESULT h017: -0.78 (-39.0bb); session -1.42 (-71.0bb in 17 hands, -418 bb/100)
```

- **Starting stack:** the stack read plus any blind you had posted.
- **Big blind:** half the minimum raise shown on the Raise button when it's folded to you. That's exact at any stakes.
- **Chips added after a hand you folded** at your first decision aren't counted, since that hand can only have lost the blind.
- **Ctrl-C:** the last hand is counted too, from a stack read taken 2.5s after your cards leave the screen.
- **Old runs:** `pokerbot results <run>` rebuilds the ledger from a run's screenshots.

## Shadow mode

`pokerbot shadow`:
- **You play; the bot clicks nothing,** not even OPEN. It decides every spot as usual.
- **Your clicks are recorded:** a listen-only event tap maps them to the table's buttons.
- **Both sides are logged:** `SHADOW (h012_flop_turn): bot 33 -> raise` and `… you call`, also saved to `shadow.tsv`.
- **The model sees your play:** it's told your preflop action, not its own.
- **The stats scanner is off,** because it would move your mouse. Saved stats are still used.

`pokerbot report` shows:
- your agreement with the bot, by street;
- both styles side by side: preflop raise/call/fold, postflop bet/check-call/fold, and aggression;
- every disagreement, with its cards, stats and the bot's reason.

## Testing strategies on past hands

The replay tools re-run the decider on decisions you actually played, using the saved screenshots. Each spot's context is rebuilt by the current engine, so reader changes are tested together with the prompt.

A **strategy variant** is a shell file that `decide.sh` sources, for example `prompts/no-floats.sh`:

```sh
POKER_BASE="$POKER_BASE Facing a bet with no pair, continue only with a flush draw or an open-ended straight draw..."
```

The tools:
- **`pokerbot bench [--variant prompts/x.sh] [--backend …] [--model …] [--effort …] [--repeat 3]`** scores the benchmark: `bench/spots.json`, a set of your past spots each with a clear right answer. A spot passes when every repeat picks an accepted action. A dozen spots take about 15 seconds. The benchmark is yours to build with `bench/add.py`. It isn't kept in git, because its screenshots and saved contexts show other players' names and stats.
- **`pokerbot bench --all /tmp/poker/<run>...`** re-decides every model decision in those runs and saves the answers.
- **`bench/compare.py <a>.json <b>.json`** diffs two `--all` runs decision by decision. Run the default twice first: the model changes about 8% of its answers with nothing changed, mostly 33 vs 50 vs 75. Only differences well beyond that mean something.
- **`bench/add.py <run>/<shot> --id <name> --expect <actions> --note "<why>"`** adds a spot. Expectations are actions (`fold`, `call`, `raise`, `33`, `50`, `75`, `max`) or groups: `bet`, `big` (75/max), `value` (50/75/max), `small`. Add only spots with a clear answer.

Replay scores decisions, not winnings. What would have happened after a different action can't be known: opponents' hidden cards and their reactions to that action don't exist. Winnings come from the RESULT lines in real play.

## Tests

`pokerbot test` (or `make test`) runs three groups:
- **`engine --selftest`:**
  - amount parsing (the "O.1" zero) and name matching (lookalike letters, truncated names);
  - hand descriptions checked at the table;
  - action words and preset fitting;
  - the results ledger (big blind from the Raise button, ignoring added chips) and the stats-window layout.
- **The card reader** on `tests/fixtures/`. These are real screenshots masked down to the card areas, so no other players' names are stored. They include the cases that broke before: a 6 in the left hole slot, which was read as an 8, and a K♥ in the right slot.
- **Python tests** for parsing the model's action, and for the OpenAI-compatible backend against a stand-in server.

## Project layout

```
pokerbot              the command (subcommands, config)
dist-install.sh       the installer shipped in a release, as install.sh
decide.sh             the strategy prompt (POKER_BASE, ...) and variant hook
decide.py             model backends: claude-cli, anthropic, openai
src/                  the engine (Swift)
  main.swift          arguments and startup
  Monitor.swift       the capture loop: turns, OPEN, cashout, charts, decider, ledger, stats scans, shadow clicks
  Frame.swift         pixel detectors on a captured frame (buttons, cards face up, preset kind, ...)
  Cards.swift         card reader (glyph templates)
  HandStrength.swift  exact hand and draws
  Preflop.swift       seat tags, positions, chart lookup and adjustments
  Stats.swift         the stats window, seat names, the price of a call
  Results.swift       stack and pot reading, the results ledger
  Clicking.swift      buttons, clicks, focus hand-back
  Decider.swift       one-shot and per-hand model sessions
  Shadow.swift        recording your clicks
  Window.swift        finding the table window
  Tools.swift         --selftest, --read-cards, --context, --results, ... and template building
cards.txt             card glyph templates
preflop_charts.json   preflop solutions
bench/                replay benchmark (run.py, add.py, compare.py; your spots.json, not in git)
prompts/              strategy variants
shadow_report.py      shadow-mode comparison
tests/                self-tests and masked card fixtures
```

## Troubleshooting and tools

`pokerbot tools <tool> <args>` runs the engine's tools on saved screenshots (`pokerbot tools` lists them):

| Tool | Shows |
|---|---|
| `--read-cards <png>...` | the cards, hand and draws read |
| `--context <png>...` | the full context line the model would get |
| `--read-preflop <png>...` | the seat tags, positions, chart spot and the chart's play |
| `--read-seats <png>...` | the names on the seats |
| `--read-hud <png>...` | what the stats-window reader sees |
| `--results <run>` | the results ledger of a run |
| `--selftest` | the engine's logic self-tests |
| `--build-cards <labels> <png-dir> <out>` | rebuilds `cards.txt` from labelled screenshots (`<png> <slot> <rank> <suit>` per line). It reports leave-one-screenshot-out accuracy; currently 560/560. |

Common problems:
- **`ENGINE: table window not found`:** open a table. The lobby and the stats window are never mistaken for it.
- **It sits idle:** run with `--debug` and look at `cur.png` to see what the engine sees.
- **A card shows as `?`, or a read is wrong:** add the screenshot to the template labels and rebuild with `--build-cards`. Then add a masked fixture to `tests/` so the mistake can't come back.
- **The table layout changed:** button positions are fractions of the content area (`buttons` in `src/Clicking.swift`), and the detectors are in `src/Frame.swift`.
