from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import numpy as np


WORKER_DIR = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_DIR))

import sensitive_content_worker as worker  # noqa: E402


class WorkerContractTests(unittest.TestCase):
    def test_cpu_threads_scale_to_physical_core_estimate_and_validate_override(self) -> None:
        with (
            patch.object(worker.os, "cpu_count", return_value=12),
            patch.dict(worker.os.environ, {"SENSITIVE_CONTENT_CPU_THREADS": ""}),
        ):
            self.assertEqual(worker.cpu_inference_threads(), 6)
        with (
            patch.object(worker.os, "cpu_count", return_value=12),
            patch.dict(worker.os.environ, {"SENSITIVE_CONTENT_CPU_THREADS": "8"}),
        ):
            self.assertEqual(worker.cpu_inference_threads(), 8)
        with (
            patch.object(worker.os, "cpu_count", return_value=4),
            patch.dict(worker.os.environ, {"SENSITIVE_CONTENT_CPU_THREADS": "8"}),
        ):
            with self.assertRaises(worker.WorkerError):
                worker.cpu_inference_threads()

    def test_models_only_load_sessions_required_by_enabled_categories(self) -> None:
        root = Path("runtime")
        calibration = {"bloodGoreFusion": {"enabled": True}}
        with patch.object(worker, "session", side_effect=lambda path, _backend: path) as load:
            adult = worker.Models(
                root,
                {
                    "adult_nudity": True,
                    "blood_gore": False,
                    "violence_weapons": False,
                },
                calibration,
            )
        self.assertIsNotNone(adult.safety)
        self.assertIsNotNone(adult.multi)
        self.assertIsNone(adult.temporal)
        self.assertIsNone(adult.blood_calibration)
        self.assertEqual(load.call_count, 2)

        with patch.object(worker, "session", side_effect=lambda path, _backend: path) as load:
            violence = worker.Models(
                root,
                {
                    "adult_nudity": False,
                    "blood_gore": False,
                    "violence_weapons": True,
                },
                calibration,
            )
        self.assertIsNone(violence.safety)
        self.assertIsNotNone(violence.multi)
        self.assertIsNotNone(violence.temporal)
        self.assertIsNone(violence.blood_calibration)
        self.assertEqual(load.call_count, 2)

        with (
            patch.object(worker, "session", side_effect=lambda path, _backend: path) as load,
            patch.object(
                worker, "load_anime_blood_tag_indices", return_value=(0, (1,))
            ),
        ):
            blood = worker.Models(
                root,
                {
                    "adult_nudity": False,
                    "blood_gore": True,
                    "violence_weapons": False,
                },
                calibration,
            )
        self.assertIsNotNone(blood.safety)
        self.assertIsNotNone(blood.multi)
        self.assertIsNotNone(blood.temporal)
        self.assertIsNotNone(blood.anime)
        self.assertEqual(blood.blood_calibration, calibration["bloodGoreFusion"])
        self.assertEqual(load.call_count, 4)

    def test_backend_prefers_directml_and_honors_cpu_override(self) -> None:
        with (
            patch.object(
                worker.ort,
                "get_available_providers",
                return_value=["DmlExecutionProvider", "CPUExecutionProvider"],
            ),
            patch.dict(
                worker.os.environ,
                {"SENSITIVE_CONTENT_EXECUTION_PROVIDER": "auto"},
            ),
        ):
            backend = worker.InferenceBackend()
            self.assertEqual(backend.active_provider, "directml")
            options = backend.options("directml")
            self.assertFalse(options.enable_mem_pattern)
            self.assertEqual(options.execution_mode, worker.ort.ExecutionMode.ORT_SEQUENTIAL)
        with (
            patch.object(
                worker.ort,
                "get_available_providers",
                return_value=["DmlExecutionProvider", "CPUExecutionProvider"],
            ),
            patch.dict(
                worker.os.environ,
                {"SENSITIVE_CONTENT_EXECUTION_PROVIDER": "cpu"},
            ),
        ):
            self.assertEqual(worker.InferenceBackend().active_provider, "cpu")

    def test_emit_replaces_unpaired_surrogates_with_valid_json_text(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            worker.emit({"type": "error", "message": "bad\udc90path"})
        line = output.getvalue()
        self.assertNotIn(r"\udc90", line)
        self.assertIn(r"\ufffd", line)
        self.assertEqual(json.loads(line)["message"], "bad\ufffdpath")

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

    def test_blood_color_evidence_requires_localized_and_global_support(self) -> None:
        calibration = {
            "redMinimum": 85,
            "redMaximum": 210,
            "greenMaximum": 120,
            "blueMaximum": 120,
            "redToGreenRatio": 1.4,
            "redGreenOffset": 8,
            "redToBlueRatio": 1.22,
            "redBlueOffset": 6,
            "redGreenDifference": 35,
            "localGrid": 7,
            "activeLocalRatioFloor": 0.02,
            "maximumActiveLocalCells": 3,
            "maximumGlobalRatio": 0.006,
            "globalRatioFloor": 0.0008,
            "globalRatioFullScale": 0.0025,
            "localRatioFloor": 0.02,
            "localRatioFullScale": 0.1,
            "temporalEvidenceFloor": 0.18,
            "temporalMinimumEvidenceFrames": 2,
        }
        safe = np.full((worker.FRAME_SIZE, worker.FRAME_SIZE, 3), 96, dtype=np.uint8)
        blood = safe.copy()
        blood[100:116, 100:116] = np.asarray([145, 28, 38], dtype=np.uint8)
        yellow = safe.copy()
        yellow[:, :] = np.asarray([220, 170, 60], dtype=np.uint8)
        red_title = safe.copy()
        red_title[64:160, 32:192] = np.asarray([190, 35, 45], dtype=np.uint8)
        red_lips = safe.copy()
        red_lips[96:110, 92:112] = np.asarray([175, 45, 55], dtype=np.uint8)
        red_lips[112:126, 96:116] = np.asarray([175, 45, 55], dtype=np.uint8)
        self.assertEqual(worker.blood_color_evidence(safe, calibration), 0.0)
        self.assertGreater(worker.blood_color_evidence(blood, calibration), 0.95)
        self.assertEqual(worker.blood_color_evidence(yellow, calibration), 0.0)
        self.assertEqual(worker.blood_color_evidence(red_title, calibration), 0.0)
        self.assertEqual(worker.blood_color_evidence(red_lips, calibration), 0.0)

    def test_temporal_blood_color_requires_persistent_evidence(self) -> None:
        calibration = {
            "temporalEvidenceFloor": 0.18,
            "temporalMinimumEvidenceFrames": 2,
        }
        self.assertEqual(
            worker.temporal_blood_color_evidence(
                [0.0, 0.95, 0.0, 0.1], calibration
            ),
            0.0,
        )
        self.assertEqual(
            worker.temporal_blood_color_evidence(
                [0.0, 0.61, 0.83, 0.0], calibration
            ),
            0.83,
        )

    def test_blood_fusion_detects_anime_blood_and_rejects_red_aura(self) -> None:
        profile = {
            "bloodCandidateViolenceThreshold": 0.75,
            "bloodColorCandidateThreshold": 0.75,
            "bloodContextThreshold": 0.72,
            "bloodNsflAssistScale": 0.45,
        }
        anime_blood = {
            "blood_gore": 0.0667,
            "_blood_color": 1.0,
            "_violence_static": 0.9592,
        }
        red_aura = {
            "blood_gore": 0.0298,
            "_blood_color": 1.0,
            "_violence_static": 0.036,
        }
        self.assertTrue(worker.blood_candidate_hit(anime_blood, profile, 0.5))
        self.assertGreater(
            worker.fused_blood_gore_score(anime_blood, profile), 0.95
        )
        self.assertEqual(
            worker.fused_blood_gore_score(red_aura, profile),
            red_aura["blood_gore"],
        )

    def test_anime_blood_uses_its_own_threshold_without_lowering_general_threshold(self) -> None:
        profile = {
            "bloodContextThreshold": 0.6,
            "bloodNsflAssistScale": 0.45,
            "animeBloodTriggerThreshold": 0.8,
            "animeBloodCandidateNsflThreshold": 0.02,
            "animeBloodCandidateColorThreshold": 0.08,
            "animeBloodCandidateViolenceThreshold": 0.12,
            "animeBloodCandidateTemporalThreshold": 0.45,
        }
        target = {
            "blood_gore": 0.039,
            "_blood_color": 0.264,
            "_violence_static": 0.243,
            "_anime_blood": 0.94,
        }
        ordinary = {
            "blood_gore": 0.02,
            "_blood_color": 0.0,
            "_violence_static": 0.0,
            "_anime_blood": 0.61,
        }
        self.assertTrue(worker.anime_blood_candidate_hit(target, profile))
        self.assertEqual(worker.fused_blood_gore_score(target, profile), 0.94)
        self.assertEqual(
            worker.fused_blood_gore_score(ordinary, profile),
            ordinary["blood_gore"],
        )

    def test_temporal_blood_fusion_can_cover_low_nsfl_impact_frames(self) -> None:
        profile = {
            "bloodContextThreshold": 0.72,
            "bloodNsflAssistScale": 0.45,
        }
        score = worker.fused_blood_gore_score(
            {
                "blood_gore": 0.0,
                "_blood_color": 1.0,
                "_violence_static": 0.0,
            },
            profile,
            temporal_context=0.9484,
        )
        self.assertGreater(score, 0.95)

    def test_ffmpeg_decode_is_video_only_and_memory_streamed(self) -> None:
        command = worker.ffmpeg_decode_command(
            "ffmpeg.exe", Path("source.mp4"), 4.0, 1.5, 3.5
        )
        self.assertIn("-an", command)
        self.assertIn("-sn", command)
        self.assertIn("-dn", command)
        self.assertEqual(command[-2:], ["rawvideo", "pipe:1"])
        self.assertNotIn("-c:a", command)

    def test_exhaustive_decode_preserves_source_frames_without_fps_filter(self) -> None:
        command = worker.ffmpeg_exhaustive_decode_command(
            "ffmpeg.exe", Path("source.mp4")
        )
        filter_graph = command[command.index("-vf") + 1]
        self.assertNotIn("fps=", filter_graph)
        self.assertEqual(command[command.index("-vsync") + 1], "0")
        self.assertIn("-an", command)
        self.assertIn("-sn", command)
        self.assertIn("-dn", command)

    def test_exhaustive_scan_sends_every_decoded_frame_to_static_inference(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            1.0,
            5.0,
            {
                "adult_nudity": True,
                "blood_gore": False,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "staticBatchSize": 2,
            "refineFps": 4.0,
            "temporalFps": 4.0,
            "temporalWindowFrames": 4,
            "temporalStrideFrames": 1,
            "profiles": {
                "balanced": {
                    "triggerThreshold": 0.72,
                    "strongThreshold": 0.92,
                    "consecutiveHits": 2,
                }
            },
        }
        frames = [
            np.full(
                (worker.FRAME_SIZE, worker.FRAME_SIZE, 3), index, dtype=np.uint8
            )
            for index in range(5)
        ]

        class FakeModels:
            def __init__(self) -> None:
                self.seen: list[int] = []

            def static_scores(
                self, batch: list[np.ndarray]
            ) -> list[dict[str, float]]:
                values: list[dict[str, float]] = []
                for frame in batch:
                    index = int(frame[0, 0, 0])
                    self.seen.append(index)
                    values.append(
                        {
                            "adult_nudity": 0.8 if index == 3 else 0.0,
                            "blood_gore": 0.0,
                            "violence_weapons": 0.0,
                            "_blood_color": 0.0,
                            "_violence_static": 0.0,
                        }
                    )
                return values

            def enrich_anime_blood(self, *_args: object, **_kwargs: object) -> None:
                return None

        models = FakeModels()
        decoded = (
            (index, index / request.source_fps, frame)
            for index, frame in enumerate(frames)
        )
        with patch.object(worker, "decoded_source_frames", return_value=decoded):
            observations = worker.exhaustive_scan(
                request, calibration, models, "ffmpeg.exe"
            )
        self.assertEqual(models.seen, [0, 1, 2, 3, 4])
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0].start, 0.6)

    def test_exhaustive_segments_keep_a_single_valid_frame(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            10.0,
            30.0,
            {
                "adult_nudity": False,
                "blood_gore": True,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "refineFps": 4.0,
            "exhaustiveConsecutiveHits": 1,
            "maxOutputSegments": 100,
            "profiles": {
                "balanced": {
                    "strongThreshold": 0.92,
                    "consecutiveHits": 2,
                }
            },
        }
        segments = worker.observations_to_segments(
            [worker.Observation(7.0, 7.0 + 1.0 / 30.0, "blood_gore", 0.8)],
            request,
            calibration,
        )
        self.assertEqual(len(segments), 1)
        self.assertEqual(segments[0]["sourceStart"], 7.0)

    def test_temporal_fusion_localizes_evidence_between_temporal_samples(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            2.0,
            8.0,
            {
                "adult_nudity": False,
                "blood_gore": True,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "staticBatchSize": 16,
            "refineFps": 2.0,
            "temporalFps": 2.0,
            "temporalWindowFrames": 4,
            "temporalStrideFrames": 1,
            "profiles": {
                "balanced": {
                    "triggerThreshold": 0.72,
                    "bloodContextThreshold": 0.6,
                    "bloodNsflAssistScale": 0.45,
                }
            },
        }
        frames = [
            np.full(
                (worker.FRAME_SIZE, worker.FRAME_SIZE, 3), index, dtype=np.uint8
            )
            for index in range(16)
        ]

        class FakeModels:
            blood_calibration = {
                "temporalEvidenceFloor": 0.18,
                "temporalMinimumEvidenceFrames": 2,
            }

            def static_scores(
                self, batch: list[np.ndarray]
            ) -> list[dict[str, float]]:
                return [
                    {
                        "adult_nudity": 0.0,
                        # Frame 2 sits between temporal samples 0 and 4.
                        "blood_gore": 0.4 if int(frame[0, 0, 0]) == 2 else 0.0,
                        "violence_weapons": 0.0,
                        "_blood_color": 0.0,
                        "_violence_static": 0.0,
                    }
                    for frame in batch
                ]

            def temporal_score(self, _frames: list[np.ndarray]) -> float:
                return 0.9

            def enrich_anime_blood(self, *_args: object, **_kwargs: object) -> None:
                return None

        decoded = (
            (index, index / request.source_fps, frame)
            for index, frame in enumerate(frames)
        )
        with patch.object(worker, "decoded_source_frames", return_value=decoded):
            observations = worker.exhaustive_scan(
                request, calibration, FakeModels(), "ffmpeg.exe"
            )
        blood = [
            value for value in observations if value.category == "blood_gore"
        ]
        self.assertEqual(len(blood), 1)
        self.assertEqual(blood[0].start, 2 / request.source_fps)
        self.assertEqual(blood[0].end, 3 / request.source_fps)
        self.assertGreater(blood[0].score, 0.85)

    def test_overlapping_temporal_windows_do_not_duplicate_a_source_frame(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            3.0,
            8.0,
            {
                "adult_nudity": False,
                "blood_gore": True,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "staticBatchSize": 24,
            "refineFps": 2.0,
            "temporalFps": 2.0,
            "temporalWindowFrames": 4,
            "temporalStrideFrames": 1,
            "profiles": {
                "balanced": {
                    "triggerThreshold": 0.72,
                    "bloodContextThreshold": 0.6,
                    "bloodNsflAssistScale": 0.45,
                }
            },
        }
        frames = [
            np.full(
                (worker.FRAME_SIZE, worker.FRAME_SIZE, 3), index, dtype=np.uint8
            )
            for index in range(24)
        ]

        class FakeModels:
            blood_calibration = {
                "temporalEvidenceFloor": 0.18,
                "temporalMinimumEvidenceFrames": 2,
            }

            def static_scores(
                self, batch: list[np.ndarray]
            ) -> list[dict[str, float]]:
                return [
                    {
                        "adult_nudity": 0.0,
                        "blood_gore": 0.4 if int(frame[0, 0, 0]) == 10 else 0.0,
                        "violence_weapons": 0.0,
                        "_blood_color": 0.0,
                        "_violence_static": 0.0,
                    }
                    for frame in batch
                ]

            def temporal_score(self, _frames: list[np.ndarray]) -> float:
                return 0.9

            def enrich_anime_blood(self, *_args: object, **_kwargs: object) -> None:
                return None

        decoded = (
            (index, index / request.source_fps, frame)
            for index, frame in enumerate(frames)
        )
        with patch.object(worker, "decoded_source_frames", return_value=decoded):
            observations = worker.exhaustive_scan(
                request, calibration, FakeModels(), "ffmpeg.exe"
            )
        blood = [
            value for value in observations if value.category == "blood_gore"
        ]
        self.assertEqual(len(blood), 1)
        self.assertEqual(blood[0].start, 10 / request.source_fps)

    def test_temporal_fusion_does_not_mix_static_evidence_across_frames(self) -> None:
        request = worker.AnalysisRequest(
            Path("fixture.mp4"),
            2.0,
            8.0,
            {
                "adult_nudity": False,
                "blood_gore": True,
                "violence_weapons": False,
            },
            "balanced",
        )
        calibration = {
            "staticBatchSize": 16,
            "refineFps": 2.0,
            "temporalFps": 2.0,
            "temporalWindowFrames": 4,
            "temporalStrideFrames": 1,
            "profiles": {
                "balanced": {
                    "triggerThreshold": 0.72,
                    "bloodContextThreshold": 0.6,
                    "bloodNsflAssistScale": 0.45,
                }
            },
        }
        frames = [
            np.full(
                (worker.FRAME_SIZE, worker.FRAME_SIZE, 3), index, dtype=np.uint8
            )
            for index in range(16)
        ]

        class FakeModels:
            blood_calibration = {
                "temporalEvidenceFloor": 0.18,
                "temporalMinimumEvidenceFrames": 2,
            }

            def static_scores(
                self, batch: list[np.ndarray]
            ) -> list[dict[str, float]]:
                return [
                    {
                        "adult_nudity": 0.0,
                        "blood_gore": 0.4 if int(frame[0, 0, 0]) == 2 else 0.0,
                        "violence_weapons": 0.0,
                        "_blood_color": (
                            1.0 if int(frame[0, 0, 0]) in (10, 11) else 0.0
                        ),
                        "_violence_static": (
                            0.9 if int(frame[0, 0, 0]) == 6 else 0.0
                        ),
                    }
                    for frame in batch
                ]

            def temporal_score(self, _frames: list[np.ndarray]) -> float:
                return 0.0

            def enrich_anime_blood(self, *_args: object, **_kwargs: object) -> None:
                return None

        decoded = (
            (index, index / request.source_fps, frame)
            for index, frame in enumerate(frames)
        )
        with patch.object(worker, "decoded_source_frames", return_value=decoded):
            observations = worker.exhaustive_scan(
                request, calibration, FakeModels(), "ffmpeg.exe"
            )
        self.assertEqual(observations, [])

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
