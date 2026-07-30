from __future__ import annotations

import sys
import unittest
from pathlib import Path


QUALIFICATION_DIR = Path(__file__).resolve().parents[1] / "qualification"
sys.path.insert(0, str(QUALIFICATION_DIR))

import evaluate  # noqa: E402


class QualificationMetricTests(unittest.TestCase):
    def test_time_metrics_and_event_miss_rate(self) -> None:
        accumulator = evaluate.metric_accumulator()
        evaluate.add_metrics(
            accumulator,
            [(1.0, 3.0), (7.0, 8.0)],
            [(0.5, 2.0), (4.0, 5.0)],
            10.0,
        )
        metrics = evaluate.finalize_metrics(accumulator)
        self.assertAlmostEqual(metrics["segmentPrecision"], 1.0 / 2.5)
        self.assertAlmostEqual(metrics["segmentRecall"], 1.0 / 3.0)
        self.assertAlmostEqual(metrics["falseNegativeEventRate"], 0.5)
        self.assertEqual(metrics["boundaryLeadSecondsP95"], 0.5)
        self.assertEqual(metrics["boundaryLagSecondsP95"], 0.0)

    def test_segment_normalization_merges_and_filters_categories(self) -> None:
        segments = evaluate.normalize_segments(
            [
                {
                    "sourceStart": 1.0,
                    "sourceEnd": 2.0,
                    "categories": ["blood_gore"],
                },
                {
                    "sourceStart": 1.5,
                    "sourceEnd": 3.0,
                    "categories": ["blood_gore"],
                },
                {
                    "sourceStart": 4.0,
                    "sourceEnd": 5.0,
                    "categories": ["adult_nudity"],
                },
            ],
            10.0,
            "blood_gore",
        )
        self.assertEqual(segments, [(1.0, 3.0)])


if __name__ == "__main__":
    unittest.main()
