"""The decider: sends a table screenshot plus the engine's context to a language model and prints its
reply (a short reason, then the action on the last line). Started by decide.sh, which sets the prompt
text (POKER_BASE, POKER_TURN, POKER_PRE, POKER_REPLY) and the strategy variant.

  decide.py <screenshot.png> <turn|premove> [context]   one decision
  decide.py --session                                   one hand: reads "png<TAB>mode<TAB>context" lines,
                                                        answers each followed by a "<<END>>" line

Backends (POKER_BACKEND):
  claude-cli  the Claude Code CLI with your Claude login (default; no API key)
  anthropic   the Anthropic API through the official SDK (pip install anthropic; ANTHROPIC_API_KEY)
  openai      any OpenAI-compatible chat endpoint: OpenAI, Ollama, LM Studio, vLLM...
              (POKER_BASE_URL, e.g. http://localhost:11434/v1 for Ollama; key in POKER_API_KEY_ENV's
              variable, OPENAI_API_KEY by default, none needed for local servers)
POKER_MODEL and POKER_EFFORT pick the model and its effort (effort applies to Claude only).
"""
import base64, json, os, subprocess, sys, tempfile, urllib.request

END = "<<END>>"
ENV = os.environ
BACKEND = ENV.get("POKER_BACKEND", "claude-cli")
MODEL = ENV.get("POKER_MODEL", "opus")
EFFORT = ENV.get("POKER_EFFORT", "low")
TRUST = " (Read exactly from the table: trust these over the image.)"
HAND = "This conversation is one hand: you get a new screenshot each time I need a decision."
# short names for the API; the CLI takes them as they are
CLAUDE_IDS = {"opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5", "fable": "claude-fable-5-2"}


def small_png(path):
    """The screenshot shrunk to 742px wide (about 1,500 fewer input tokens, ~0.5s faster)."""
    out = os.path.join(tempfile.mkdtemp(), "table.png")
    path = os.path.expanduser(path)
    r = subprocess.run(["sips", "-Z", "742", path, "--out", out], capture_output=True)
    if r.returncode != 0 or not os.path.exists(out):     # sips can fail yet exit 0: send the original
        os.rmdir(os.path.dirname(out)) if os.path.isdir(os.path.dirname(out)) and not os.listdir(os.path.dirname(out)) else None
        return path
    return out


def image_b64(path):
    if path in ("", "-"):                    # a spot described only in text (e.g. the hand library)
        return None
    small = small_png(path)
    with open(small, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    if small != path:
        os.remove(small)
        os.rmdir(os.path.dirname(small))
    return data


def user_text(mode, context, first, base_in_text):
    """The text of one decision's message. The prompt's base goes in the first message for the CLI
    (no system prompt there) and in the system prompt for the API backends."""
    task = ENV["POKER_PRE"] if mode == "premove" else ENV["POKER_TURN"]
    lines = []
    if context:
        lines.append(context + (TRUST if first else ""))
    if first and base_in_text:
        lines.append(ENV["POKER_BASE"])
    if first and SESSION:
        lines.append(HAND)
    lines += [task, ENV["POKER_REPLY"]]
    return "\n".join(lines)


class ClaudeCLI:
    """One `claude -p` process per hand (stream-json in and out), started right away so its startup
    is hidden behind the deal; later messages reuse the cached conversation."""
    base_in_text = True

    def __init__(self):
        self.proc = subprocess.Popen(
            ["claude", "-p", "--model", MODEL, "--effort", EFFORT, "--tools", "", "--strict-mcp-config",
             "--disable-slash-commands", "--no-session-persistence",
             "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def ask(self, img, text):
        msg = {"type": "user", "message": {"role": "user", "content": [
            *([{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": img}}] if img else []),
            {"type": "text", "text": text}]}}
        try:
            self.proc.stdin.write(json.dumps(msg) + "\n")
            self.proc.stdin.flush()
        except BrokenPipeError:
            return None
        for out in self.proc.stdout:
            try:
                d = json.loads(out)
            except ValueError:
                continue
            if d.get("type") == "result":
                return d.get("result") or ""
        return None

    def close(self):
        try:
            self.proc.stdin.close()
        except BrokenPipeError:
            pass
        self.proc.wait()


class AnthropicAPI:
    """The Messages API: the prompt's base is a cached system prompt, the hand's turns accumulate."""
    base_in_text = False

    def __init__(self):
        import anthropic                      # pip install anthropic
        self.client = anthropic.Anthropic()   # ANTHROPIC_API_KEY (or an `ant auth login` profile)
        self.model = CLAUDE_IDS.get(MODEL, MODEL)
        self.messages = []

    def ask(self, img, text):
        self.messages.append({"role": "user", "content": [
            *([{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": img}}] if img else []),
            {"type": "text", "text": text}]})
        try:
            r = self.client.beta.messages.create(
                model=self.model, max_tokens=4000,
                system=[{"type": "text", "text": ENV["POKER_BASE"], "cache_control": {"type": "ephemeral"}}],
                messages=self.messages,
                output_config={"effort": EFFORT},
                # a policy decline is re-run on a fallback model chosen by the API
                betas=["server-side-fallback-2026-07-01"], fallbacks="default")
        except Exception as e:                # the engine treats no answer as no action
            print(f"decide.py: {type(e).__name__}: {e}", file=sys.stderr)
            self.messages.pop()
            return None
        self.messages.append({"role": "assistant", "content": r.content})
        if r.stop_reason == "refusal":
            return None
        return "".join(b.text for b in r.content if b.type == "text")

    def close(self):
        pass


class OpenAICompatible:
    """Any OpenAI-style /chat/completions endpoint, with the screenshot as a data URL."""
    base_in_text = False

    def __init__(self):
        self.url = ENV.get("POKER_BASE_URL", "https://api.openai.com/v1").rstrip("/") + "/chat/completions"
        self.key = ENV.get(ENV.get("POKER_API_KEY_ENV", "OPENAI_API_KEY"), "")
        self.messages = [{"role": "system", "content": ENV["POKER_BASE"]}]

    def ask(self, img, text):
        self.messages.append({"role": "user", "content": [
            {"type": "text", "text": text},
            *([{"type": "image_url", "image_url": {"url": "data:image/png;base64," + img}}] if img else [])]})
        body = json.dumps({"model": MODEL, "messages": self.messages, "max_tokens": 1000}).encode()
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        try:
            with urllib.request.urlopen(urllib.request.Request(self.url, body, headers), timeout=60) as resp:
                reply = json.load(resp)["choices"][0]["message"]["content"] or ""
        except Exception as e:
            print(f"decide.py: {type(e).__name__}: {e}", file=sys.stderr)
            self.messages.pop()
            return None
        self.messages.append({"role": "assistant", "content": reply})
        return reply

    def close(self):
        pass


BACKENDS = {"claude-cli": ClaudeCLI, "anthropic": AnthropicAPI, "openai": OpenAICompatible}
SESSION = len(sys.argv) > 1 and sys.argv[1] == "--session"


def main():
    if BACKEND not in BACKENDS:
        sys.exit(f"decide.py: unknown POKER_BACKEND '{BACKEND}' (one of {', '.join(BACKENDS)})")
    backend = BACKENDS[BACKEND]()
    if not SESSION:
        if len(sys.argv) < 2:
            sys.exit(__doc__)
        png, mode = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "turn"
        context = sys.argv[3] if len(sys.argv) > 3 else ""
        reply = backend.ask(image_b64(png), user_text(mode, context, True, backend.base_in_text))
        backend.close()
        if reply is not None:
            print(reply)
        return
    first = True
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2:
            continue
        png, mode, context = parts[0], parts[1], parts[2] if len(parts) > 2 else ""
        reply = backend.ask(image_b64(png), user_text(mode, context, first, backend.base_in_text))
        first = False
        print(reply or "", flush=True)
        print(END, flush=True)
    backend.close()


if __name__ == "__main__":
    main()
