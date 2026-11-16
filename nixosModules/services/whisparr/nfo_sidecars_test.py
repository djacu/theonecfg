import tempfile
import unittest
from pathlib import Path

import nfo_sidecars


def title_of(folder, filename):
    return nfo_sidecars.parse(Path("/tank0/media/adult") / folder / filename)


class ParseTest(unittest.TestCase):
    def test_standard_shape(self):
        title, premiered = title_of(
            "Pure Taboo",
            "2024-11-29 - Pure Taboo - Be A Real Man [WEBDL-1080p].mp4",
        )
        self.assertEqual(title, "Be A Real Man")
        self.assertEqual(premiered, "2024-11-29")

    def test_studio_name_containing_separator(self):
        # 69 studio folders contain " - " in their own name; a non-greedy
        # split on " - " would cut the studio in half and leave its tail
        # glued to the front of the title.
        title, premiered = title_of(
            "FansDB - Emakarter1 (onlyfans)",
            "2024-03-15 - FansDB - Emakarter1 (onlyfans) - His Massive Cock"
            " Hit Me So Deep [WEBDL-1080p].mp4",
        )
        self.assertEqual(title, "His Massive Cock Hit Me So Deep")
        self.assertEqual(premiered, "2024-03-15")

    def test_jav_code_is_kept_in_the_title(self):
        # Stash titles these as the bare code; the filename is the only
        # place the full title survives.
        title, _ = title_of(
            "MADONNA",
            "2022-09-09 - MADONNA - JUQ-078 Super Beautiful Nude Married"
            " Woman Madonna Exclusive Chapter 3 [HDTV-1080p].mp4",
        )
        self.assertTrue(title.startswith("JUQ-078 Super Beautiful"))

    def test_unparseable_name_falls_back_to_stem(self):
        title, premiered = title_of("Scoop", "scop-931.mp4")
        self.assertEqual(title, "scop-931")
        self.assertIsNone(premiered)

    def test_quality_tag_with_extra_words(self):
        title, _ = title_of(
            "My Pervy Family",
            "2026-04-09 - My Pervy Family - My Stepsisters Actual REAL"
            " Pussy!!! [WEBDL-1080p REAL].mp4",
        )
        self.assertEqual(title, "My Stepsisters Actual REAL Pussy!!!")


class SweepTest(unittest.TestCase):
    def test_writes_updates_and_removes_orphans(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            studio = root / "Attackers"
            studio.mkdir()
            video = studio / "2021-01-07 - Attackers - SHKD-925 [WEBDL-480p].mp4"
            video.touch()
            orphan = studio / "gone.nfo"
            orphan.write_bytes(b"stale")

            written, removed = nfo_sidecars.sweep([root])
            self.assertEqual((written, removed), (1, 1))
            self.assertFalse(orphan.exists())

            sidecar = video.with_suffix(".nfo")
            body = sidecar.read_text()
            self.assertIn("<title>SHKD-925</title>", body)
            self.assertIn("<premiered>2021-01-07</premiered>", body)

            # Second pass is a no-op: content already matches.
            self.assertEqual(nfo_sidecars.sweep([root]), (0, 0))

            # A stale sidecar is rewritten, not left alone.
            sidecar.write_bytes(b"<movie><title>wrong</title></movie>")
            self.assertEqual(nfo_sidecars.sweep([root]), (1, 0))

    def test_orphan_test_ignores_the_extension_list(self):
        # .iso is not in VIDEO_EXTENSIONS, so no sidecar is generated for
        # it -- but a sidecar someone else put there must survive.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scene.iso").touch()
            kept = root / "scene.nfo"
            kept.write_bytes(b"<movie><title>hand written</title></movie>")

            self.assertEqual(nfo_sidecars.sweep([root]), (0, 0))
            self.assertTrue(kept.exists())


if __name__ == "__main__":
    unittest.main()
