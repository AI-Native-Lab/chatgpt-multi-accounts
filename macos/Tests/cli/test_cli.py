"""End-to-end tests for the chatgpt-multi command, against a pretend ChatGPT made of files.

Run from macos/ after `swift build`:  /usr/bin/python3 -m unittest discover -s Tests/cli -v
Standard library only. Nothing here starts ChatGPT or touches the real ~/.codex.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MACOS = os.path.dirname(os.path.dirname(HERE))


def binary():
    out = subprocess.run(["swift", "build", "--show-bin-path"], cwd=MACOS, capture_output=True, text=True, check=True)
    return os.path.join(out.stdout.strip(), "chatgpt-multi")


BIN = binary()


class CLITests(unittest.TestCase):
    def setUp(self):
        # A short folder: ChatGPT's socket paths must fit in 103 bytes.
        self.root = tempfile.mkdtemp(prefix="cma-", dir="/tmp")
        self.home = os.path.join(self.root, "home")
        self.main = os.path.join(self.root, "main-codex")
        self.app = os.path.join(self.root, "ChatGPT.app")
        os.makedirs(self.app)
        os.makedirs(self.main)
        self.marker = os.path.join(self.app, "running")
        open(self.marker, "w").close()  # the main ChatGPT runs
        self.env = {
            "PATH": "/usr/bin:/bin",
            "HOME": self.root,
            "CMA_HOME": self.home,
            "CMA_MAIN_CODEX_HOME": self.main,
            "CMA_MAIN_DATA": os.path.join(self.root, "main-data"),
            "CMA_APP_SUPPORT": os.path.join(self.root, "AppSupport"),
            "CMA_FAKE_APP": self.marker,
        }

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def run_cli(self, *args, ok=True, **extra):
        env = dict(self.env, **extra)
        result = subprocess.run([BIN, *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if ok:
            self.assertEqual(result.returncode, 0, f"{args}: {result.stdout}{result.stderr}")
        else:
            self.assertNotEqual(result.returncode, 0, f"{args} should fail: {result.stdout}")
        return result.stdout + result.stderr

    def listing(self):
        return json.loads(self.run_cli("list", "--json"))

    def test_emptyList(self):
        out = self.run_cli("list")
        self.assertIn("Main ChatGPT (open): signed out", out)
        self.assertIn("No other accounts yet", out)

    def test_addSeveralAndUseThemAtOnce(self):
        out = self.run_cli("add", "--name", "Work", CMA_FAKE_SIGN_IN="work@example.com")
        self.assertIn("A new ChatGPT window opened at its sign-in screen", out)
        self.run_cli("add", CMA_FAKE_SIGN_IN="client@example.com")
        self.run_cli("add")  # opens at the sign-in screen and stays there

        data = self.listing()
        self.assertEqual(data["openCount"], 4)
        names = [a["displayName"] for a in data["accounts"]]
        self.assertEqual(names, ["Work", "client@example.com", "New account 3"])
        self.assertEqual(data["accounts"][0]["signIn"], {"email": "work@example.com", "plan": "plus", "mode": "chatgpt"})
        self.assertIsNone(data["accounts"][2]["signIn"])
        for account in data["accounts"]:
            self.assertTrue(account["folder"].startswith(self.home + "/"))
            self.assertTrue(os.path.isdir(os.path.join(account["folder"], "codex")))
            self.assertTrue(os.path.isdir(os.path.join(account["folder"], "data")))

        out = self.run_cli("list")
        self.assertIn("4 ChatGPT accounts are open at once.", out)
        self.assertIn("waiting for sign-in in its window", out)

    def test_closeAllAndOpenAll(self):
        self.run_cli("add", "--name", "A", CMA_FAKE_SIGN_IN="a@example.com")
        self.run_cli("add", "--name", "B", CMA_FAKE_SIGN_IN="b@example.com")
        self.assertIn("Closed 2 accounts. The main ChatGPT keeps running.", self.run_cli("close", "--all"))
        self.assertTrue(os.path.exists(self.marker), "the main ChatGPT is never quit")
        self.assertEqual(self.listing()["openCount"], 1)

        os.remove(self.marker)  # the person quit the main ChatGPT
        out = self.run_cli("open", "--all")
        self.assertIn("Opened the main ChatGPT, “A” and “B”. 3 ChatGPT accounts are open at once.", out)
        self.assertEqual(self.listing()["openCount"], 3)
        self.assertIn("Every signed-in account is already open.", self.run_cli("open", "-a"))

    def test_openAndCloseByNumberNameOrEmail(self):
        self.run_cli("add", "--name", "A", CMA_FAKE_SIGN_IN="a@example.com")
        self.assertIn("Closed “A”. It stays signed in", self.run_cli("close", "1"))
        self.assertIn("Opened “A” in its own ChatGPT window.", self.run_cli("open", "a@example.com"))
        self.assertIn("Closed “A”", self.run_cli("close", "a"))
        self.assertIn("“A” isn't open.", self.run_cli("close", "A"))
        self.assertIn("No account matches “nobody”. Accounts: 1. A.", self.run_cli("open", "nobody", ok=False))
        self.assertIn("never quits the main ChatGPT", self.run_cli("close", "main", ok=False))

    def test_renameAndRemove(self):
        self.run_cli("add", CMA_FAKE_SIGN_IN="a@example.com")
        self.run_cli("rename", "a@example.com", "Personal")
        self.assertEqual(self.listing()["accounts"][0]["name"], "Personal")
        self.assertIn("is open. Close its ChatGPT window first.", self.run_cli("remove", "1", "--yes", ok=False))
        self.assertIn("Add --yes to confirm.", self.run_cli("remove", "1", ok=False))
        self.run_cli("close", "1")
        folder = self.listing()["accounts"][0]["folder"]
        self.assertIn("Removed “Personal”.", self.run_cli("remove", "Personal", "--yes"))
        self.assertFalse(os.path.exists(folder))
        self.assertEqual(len(os.listdir(os.path.join(self.home, "Trash"))), 1)
        self.assertEqual(self.listing()["accounts"], [])

    def test_sameAccountAsMainIsShown(self):
        self.run_cli("add", CMA_FAKE_SIGN_IN="me@example.com")
        self.run_cli("add", "--name", "Me again", CMA_FAKE_SIGN_IN="me@example.com")
        # The main ChatGPT signed in to the same email.
        shutil.copy(os.path.join(self.listing()["accounts"][0]["folder"], "codex", "auth.json"),
                    os.path.join(self.main, "auth.json"))
        data = self.listing()
        self.assertEqual(data["main"]["signIn"]["email"], "me@example.com")
        self.assertEqual([a["sameAs"] for a in data["accounts"]], ["the main ChatGPT", "the main ChatGPT"])
        self.assertIn("(same account as the main ChatGPT)", self.run_cli("list"))

    def test_aCopyThatDoesNotStart(self):
        out = self.run_cli("add", "--name", "A", ok=False, CMA_FAKE_NO_START="1")
        self.assertIn("“A” didn't start.", out)
        self.assertEqual(len(self.listing()["accounts"]), 1, "kept, to open again")

    def test_doctorAndPaths(self):
        out = self.run_cli("doctor")
        self.assertIn("ok   Accounts folder", out)
        self.assertIn("Browser extension: not set up in the main ChatGPT", out)
        out = self.run_cli("paths")
        self.assertIn(self.main, out)
        self.assertIn(self.home, out)

    def test_help(self):
        self.assertIn("use several ChatGPT accounts at the same time", self.run_cli("help"))
        self.assertIn("Unknown command", self.run_cli("swap", ok=False))


if __name__ == "__main__":
    unittest.main()
