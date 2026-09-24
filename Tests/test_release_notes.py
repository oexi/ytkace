import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from Tools.release_notes import classify, collect_commits, normalize_subject, render, resolve_base


class ReleaseNotesTests(unittest.TestCase):
    def test_classifies_fix_commits(self):
        self.assertEqual(classify("fix: handle iOS Chinese caption translation"), "fix")
        self.assertEqual(classify("fix(captions): avoid delayed cues"), "fix")
        self.assertEqual(classify("Fix crash on older YouTube versions"), "fix")
        self.assertEqual(classify("Fixed keyboard not dismissing"), "fix")
        self.assertEqual(classify("Add layout mode and fix autoplay"), "change")

    def test_classifies_maintenance_commits(self):
        self.assertEqual(classify("ci: cache theos"), "maintenance")
        self.assertEqual(classify("chore: rename setting"), "maintenance")
        self.assertEqual(classify("Update readme for 1.0.1"), "maintenance")
        self.assertEqual(classify("Release 1.0.0"), "maintenance")
        self.assertEqual(classify("Prepare for next release"), "maintenance")
        self.assertEqual(
            classify("feat: publish AltStore source", (".github/workflows/build-ipa.yml", "Tools/altstore.py")),
            "maintenance",
        )
        self.assertEqual(
            classify("Add files via upload", ("Tweak/YTKACE.h", "README.md")),
            "change",
        )

    def test_normalizes_conventional_commit_subjects(self):
        self.assertEqual(
            normalize_subject("feat: add simplified Chinese caption translation"),
            "Add simplified Chinese caption translation",
        )
        self.assertEqual(normalize_subject("chore: rename setting"), "Rename setting")

    def test_renders_fork_upstream_and_maintenance_sections(self):
        notes = render(
            "0.9.3",
            "oexi/ytkace",
            [
                ("a" * 40, "feat: add simplified Chinese caption translation"),
                ("b" * 40, "fix: handle iOS Chinese caption translation"),
                ("c" * 40, "ci: publish release notes"),
            ],
            [("d" * 40, "Fix queue panel not updating")],
            since_tag="v0.9.2",
            head="e" * 40,
        )
        fork, upstream = notes.split("## Upstream changes")
        self.assertIn("## Fork changes", fork)
        self.assertIn("### Bug fixes\n- Handle iOS Chinese caption translation", fork)
        self.assertIn("### Changes\n- Add simplified Chinese caption translation", fork)
        self.assertIn("### Bug fixes\n- Fix queue panel not updating", upstream)
        self.assertIn("<summary>Maintenance (1)</summary>", upstream)
        self.assertIn("compare/v0.9.2..." + "e" * 40, notes)
        self.assertIn("releases/latest/download/altstore-source.json", notes)

    def test_renders_placeholder_without_user_facing_commits(self):
        notes = render("1.0.0", "oexi/ytkace", [("a" * 40, "ci: tweak workflow")])
        self.assertIn("- No user-facing changes.", notes)


class ReleaseRangeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.cwd = os.getcwd()
        os.chdir(self.repo)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")

    def tearDown(self):
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True).strip()

    def commit(self, subject, path="Tweak/file.mm"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a") as handle:
            handle.write(subject + "\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", subject)
        return self.git("rev-parse", "HEAD")

    def test_splits_fork_and_upstream_commits_since_previous_release(self):
        self.commit("Initial import")
        self.git("branch", "upstream")
        self.commit("feat: old fork feature", "Tweak/fork.mm")
        self.git("tag", "v1.0.0")
        self.git("checkout", "-q", "upstream")
        self.commit("Fix upstream crash", "Tweak/upstream.mm")
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--no-edit", "upstream")
        self.commit("feat: new fork feature", "Tweak/fork.mm")
        head = self.git("rev-parse", "HEAD")

        base, since = resolve_base(head, "upstream", "v1.0.0")
        self.assertEqual(since, "v1.0.0")
        fork, upstream = collect_commits(base, head, "upstream")
        self.assertEqual([c[1] for c in fork], ["feat: new fork feature"])
        self.assertEqual([c[1] for c in upstream], ["Fix upstream crash"])

    def test_falls_back_to_upstream_merge_base_without_release(self):
        self.commit("Initial import")
        self.git("branch", "upstream")
        self.commit("feat: fork feature", "Tweak/fork.mm")
        head = self.git("rev-parse", "HEAD")

        base, since = resolve_base(head, "upstream", "v9.9.9")
        self.assertIsNone(since)
        fork, upstream = collect_commits(base, head, "upstream")
        self.assertEqual([c[1] for c in fork], ["feat: fork feature"])
        self.assertEqual(upstream, [])


if __name__ == "__main__":
    unittest.main()
