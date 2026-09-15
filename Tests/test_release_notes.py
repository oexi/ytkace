import unittest

from Tools.release_notes import classify, normalize_subject, render


class ReleaseNotesTests(unittest.TestCase):
    def test_classifies_fix_commits(self):
        self.assertEqual(classify("fix: handle iOS Chinese caption translation"), "fix")
        self.assertEqual(classify("fix(captions): avoid delayed cues"), "fix")

    def test_normalizes_conventional_commit_subjects(self):
        self.assertEqual(
            normalize_subject("feat: add simplified Chinese caption translation"),
            "Add simplified Chinese caption translation",
        )

    def test_renders_bug_fixes_changes_and_altstore_source(self):
        notes = render(
            "0.9.3",
            "oexi/ytkace",
            [
                ("a" * 40, "feat: add simplified Chinese caption translation"),
                ("b" * 40, "fix: handle iOS Chinese caption translation"),
            ],
        )
        self.assertIn("## Bug fixes", notes)
        self.assertIn("Handle iOS Chinese caption translation", notes)
        self.assertIn("## Changes", notes)
        self.assertIn("Add simplified Chinese caption translation", notes)
        self.assertIn("releases/latest/download/altstore-source.json", notes)


if __name__ == "__main__":
    unittest.main()
