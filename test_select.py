"""Unit tests for Python select_ref.py logic."""
import unittest
import numpy as np
from select_ref import select

class TestSelectRef(unittest.TestCase):
    def test_select_cue_count_and_first_beat(self):
        # Create synthetic TrackAnalysis dict with 100 bars
        nb = 100
        rms = np.full(nb, -20.0)
        # make first 4 bars quiet but above threshold (-50 dB > thr)
        rms[0:4] = -40.0
        # make quiet before first bar
        rms[:0] = -80.0

        band = np.zeros((nb, 5))
        band[:, 0] = rms  # bass matches rms
        chroma = np.ones((nb, 12)) / 12.0

        # 400 beats (4 beats per bar)
        nbt = nb * 4
        beat_feat = np.random.randn(nbt, 20)
        db_beat = np.arange(0, nbt, 4)
        db_f = np.arange(0, nb) * 4.0 * 22050 / 128

        A = {
            "rms": rms,
            "band": band,
            "chroma": chroma,
            "beat_feat": beat_feat,
            "db_beat": db_beat,
            "db_f": db_f,
            "clamped": False
        }

        res = select(A, n_cues=8)
        cues = res["chosen"]
        names = res["names"]

        self.assertEqual(len(cues), 8)
        # Cue 1 should land on bar index 0 (first non-silent downbeat / beat 1)
        self.assertEqual(cues[0], 0)
        self.assertEqual(names[0], "Intro")

        # Ensure all chosen cues are sorted and unique
        self.assertEqual(cues, sorted(list(set(cues))))

if __name__ == "__main__":
    unittest.main()
