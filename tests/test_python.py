"""Python-side tests: reading the model's action, the decider's message text, and the
OpenAI-compatible backend against a stand-in server (no model, no network)."""
import json, os, subprocess, sys, threading, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
from common import action_of, allowed  # noqa: E402

FIXTURE = os.path.join(ROOT, "tests", "fixtures", "wheel-river.png")


class ActionParsing(unittest.TestCase):
    def test_last_line(self):
        self.assertEqual(action_of("Top pair, bet for value.\n75"), "75")
        self.assertEqual(action_of("Reason.\n**Call**"), "call")
        self.assertEqual(action_of("Reason.\nCheck"), "call")
        self.assertEqual(action_of("Reason.\nall-in"), "max")
        self.assertEqual(action_of("Reason ending in a word fold"), "fold")
        self.assertIsNone(action_of(""))

    def test_groups(self):
        self.assertEqual(allowed(["value"]), {"50", "75", "max"})
        self.assertIn("33", allowed(["bet"]))


class FakeChat(BaseHTTPRequestHandler):
    seen = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeChat.seen.append(body)
        out = json.dumps({"choices": [{"message": {"content": "Stand-in reason.\ncall"}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


class OpenAIBackend(unittest.TestCase):
    def test_session_keeps_the_hand(self):
        server = HTTPServer(("127.0.0.1", 0), FakeChat)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = dict(os.environ, POKER_BACKEND="openai", POKER_MODEL="test-model",
                   POKER_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1")
        lines = f"{FIXTURE}\tturn\tfirst context\n{FIXTURE}\tturn\tsecond context\n"
        out = subprocess.run([os.path.join(ROOT, "decide.sh"), "--session"], input=lines, text=True,
                             capture_output=True, env=env, timeout=60).stdout
        server.shutdown()
        server.server_close()
        self.assertEqual(out.count("<<END>>"), 2)
        self.assertEqual(action_of(out.split("<<END>>")[0]), "call")
        first, second = FakeChat.seen[-2:]
        self.assertEqual(first["model"], "test-model")
        self.assertEqual(first["messages"][0]["role"], "system")         # the strategy prompt
        self.assertIn("first context", first["messages"][1]["content"][0]["text"])
        self.assertTrue(first["messages"][1]["content"][1]["image_url"]["url"].startswith("data:image/png;base64,"))
        self.assertEqual(len(second["messages"]), 4)                     # system, turn, reply, turn


if __name__ == "__main__":
    unittest.main()
