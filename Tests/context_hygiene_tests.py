#!/usr/bin/env python3
"""Deterministische Evals fuer den kleinen, vollstaendigen Agenten-Kontext."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ContextHygieneTests(unittest.TestCase):
    def test_root_rules_fit_and_keep_invariants(self):
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertGreaterEqual(len(agents.encode("utf-8")), 6_000)
        self.assertLessEqual(len(agents.encode("utf-8")), 12_000)
        for marker in (
            "niemals Heap-Allokationen",
            "Korruption ablehnen",
            "Swift und JavaScript",
            "audio/",
            "Nie zwei Writer",
            "Produktversion nicht",
            "docs/testing.md",
            "tasks/backlog.md",
            "geschlossen und dürfen nicht reaktiviert",
        ):
            self.assertIn(marker, agents)

    def test_claude_bridge_is_thin(self):
        bridge = (ROOT / "CLAUDE.md").read_text(encoding="utf-8")
        self.assertIn("@AGENTS.md", bridge)
        self.assertLessEqual(len(bridge.encode("utf-8")), 256)

    def test_all_agent_chains_fit_codex_budget(self):
        root_size = (ROOT / "AGENTS.md").stat().st_size
        tracked = subprocess.run(
            ["git", "ls-files", "*AGENTS.md"], cwd=ROOT,
            check=True, capture_output=True, text=True).stdout.splitlines()
        for relative in tracked:
            nested = ROOT / relative
            if nested == ROOT / "AGENTS.md":
                continue
            with self.subTest(path=nested.relative_to(ROOT)):
                self.assertLessEqual(root_size + nested.stat().st_size, 32_768)

    def test_deferred_rules_and_stale_handoff_are_reachable(self):
        testing = (ROOT / "docs/testing.md").read_text(encoding="utf-8")
        backlog = (ROOT / "tasks/backlog.md").read_text(encoding="utf-8")
        handoff_head = "\n".join((ROOT / "tasks/2026-07-10-it-support/handoff.md")
                                  .read_text(encoding="utf-8").splitlines()[:10])
        state_head = "\n".join((ROOT / "tasks/2026-07-10-it-support/state.md")
                                .read_text(encoding="utf-8").splitlines()[:10])
        for marker in ("DSPChannelTimingTests", "worklet-timing.mjs",
                       "build_app.sh", "QLPreviewReply(fileURL:)",
                       "Notary-Keychain"):
            self.assertIn(marker, testing)
        self.assertIn("GUI-Smoke", backlog)
        self.assertIn("Amiga-Periodentabelle", backlog)
        self.assertIn("CLOSED / SUPERSEDED", handoff_head)
        self.assertIn("CLOSED / SUPERSEDED", state_head)

    def test_public_start_context_has_no_private_path_or_remote(self):
        text = "\n".join(
            (ROOT / path).read_text(encoding="utf-8")
            for path in ("AGENTS.md", "CLAUDE.md", "docs/testing.md",
                         "tasks/backlog.md",
                         "docs/AGENTS-history-through-2026-07-12.md")
        )
        self.assertNotIn("/Users/", text)
        self.assertNotIn("minipc", text)
        self.assertNotIn("Nextcloud", text)


if __name__ == "__main__":
    unittest.main()
