import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "Tools" / "altstore.py"
SPEC = importlib.util.spec_from_file_location("ytkace_altstore", MODULE_PATH)
ALTSTORE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(ALTSTORE)


class AltStoreTests(unittest.TestCase):
    def test_bundle_build_version_tracks_ytkace_release(self):
        self.assertEqual(
            ALTSTORE.bundle_build_version("21.36.6", "0.9.3"),
            "21.36.6000903",
        )
        self.assertEqual(
            ALTSTORE.bundle_build_version("21.36.6", "0.9.4"),
            "21.36.6000904",
        )

    def test_bundle_build_version_preserves_youtube_major_minor(self):
        self.assertEqual(
            ALTSTORE.bundle_build_version("21.33.6", "1.2.3"),
            "21.33.6010203",
        )

    def test_bundle_build_version_rejects_non_semver_input(self):
        with self.assertRaises(ValueError):
            ALTSTORE.bundle_build_version("latest", "0.9.3")


if __name__ == "__main__":
    unittest.main()
