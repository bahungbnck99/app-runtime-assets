from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


WORKER_DIR = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_DIR))

import sensitive_content_worker as worker  # noqa: E402


class WorkerContractTests(unittest.TestCase):
    def test_parse_request_is_fail_closed(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            request = worker.parse_request(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "sourcePath": source.name,
                        "sourceDuration": 12.5,
                        "sourceFps": 29.97,
                        "categories": {
                            "adult_nudity": True,
                            "blood_gore": False,
                            "violence_weapons": True,
                            "unknown": True,
                        },
                        "sensitivity": "balanced",
                    }
                )
            )
        self.assertEqual(request.sensitivity, "balanced")
        self.assertEqual(
            request.categories,
            {
                "adult_nudity": True,
                "blood_gore": False,
                "violence_weapons": True,
            },
        )

    def test_parse_request_rejects_no_enabled_category(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".mp4") as source:
            with self.assertRaisesRegex(worker.WorkerError, "At least one"):
                worker.parse_request(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "sourcePath": source.name,
                            "sourceDuration": 1,
                            "sourceFps": 30,
                            "categories": {},
                            "sensitivity": "balanced",
                        }
                    )
                )

    def test_merge_ranges_clips_and_merges(self) -> None:
        self.assertEqual(
            worker.merge_ranges(
                [(-1.0, 2.0), (1.5, 4.0), (7.0, 20.0), (5.0, 5.0)],
                10.0,
            ),
            [(0.0, 4.0), (7.0, 10.0)],
        )

    def test_ffmpeg_decode_is_video_only_and_memory_streamed(self) -> None:
        command = worker.ffmpeg_decode_command(
            "ffmpeg.exe", Path("source.mp4"), 4.0, 1.5, 3.5
        )
        self.assertIn("-an", command)
        self.assertIn("-sn", command)
        self.assertIn("-dn", command)
        self.assertEqual(command[-2:], ["rawvideo", "pipe:1"])
        self.assertNotIn("-c:a", command)

    def test_observations_require_profile_consecutive_hits(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            10.0,
            30.0,
            {
                "adult_nudity": True,
                "blood_gore": False,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "refineFps": 4.0,
            "maxOutputSegments": 100,
            "profiles": {
                "balanced": {
                    "strongThreshold": 0.92,
                    "consecutiveHits": 2,
                }
            },
        }
        segments = worker.observations_to_segments(
            [
                worker.Observation(1.0, 1.25, "adult_nudity", 0.8),
                worker.Observation(1.25, 1.5, "adult_nudity", 0.81),
                worker.Observation(5.0, 5.25, "adult_nudity", 0.93),
            ],
            request,
            calibration,
        )
        self.assertEqual(len(segments), 2)
        self.assertEqual(segments[0]["sourceStart"], 1.0)
        self.assertEqual(segments[0]["sourceEnd"], 1.5)
        self.assertEqual(segments[1]["sourceStart"], 5.0)

    def test_segments_merge_overlapping_categories(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            10.0,
            30.0,
            {category: True for category in worker.SUPPORTED_CATEGORIES},
            "sensitive",
        )
        calibration = {
            "refineFps": 4.0,
            "maxOutputSegments": 100,
            "profiles": {
                "sensitive": {
                    "strongThreshold": 0.9,
                    "consecutiveHits": 1,
                }
            },
        }
        segments = worker.observations_to_segments(
            [
                worker.Observation(2.0, 3.0, "blood_gore", 0.8),
                worker.Observation(2.5, 4.0, "violence_weapons", 0.85),
            ],
            request,
            calibration,
        )
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0]["sourceStart"], 2.0)
        self.assertEqual(segments[0]["sourceEnd"], 4.0)
        self.assertEqual(
            segments[0]["categories"], ["blood_gore", "violence_weapons"]
        )


if __name__ == "__main__":
    unittest.main()
