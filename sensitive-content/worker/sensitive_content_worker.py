from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import threading
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator

import numpy as np
import onnxruntime as ort


SCHEMA_VERSION = 1
SUPPORTED_CATEGORIES = ("adult_nudity", "blood_gore", "violence_weapons")
SUPPORTED_SENSITIVITY = ("sensitive", "balanced", "low_false_positive")
FRAME_SIZE = 224
FRAME_BYTES = FRAME_SIZE * FRAME_SIZE * 3
MAX_STDERR_BYTES = 256 * 1024
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


class WorkerError(RuntimeError):
    pass


@dataclass(frozen=True)
class AnalysisRequest:
    source_path: Path
    source_duration: float
    source_fps: float
    categories: dict[str, bool]
    sensitivity: str


@dataclass(frozen=True)
class Observation:
    start: float
    end: float
    category: str
    score: float


def configure_protocol_io() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="strict")


def json_safe(value: Any) -> Any:
    if isinstance(value, str):
        return "".join(
            "\ufffd" if 0xD800 <= ord(character) <= 0xDFFF else character
            for character in value
        )
    if isinstance(value, dict):
        return {json_safe(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    if isinstance(value, tuple):
        return [json_safe(item) for item in value]
    return value


def emit(value: dict[str, Any]) -> None:
    sys.stdout.write(
        json.dumps(json_safe(value), ensure_ascii=True, separators=(",", ":")) + "\n"
    )
    sys.stdout.flush()


def emit_progress(progress: float, stage: str, message: str | None = None) -> None:
    value: dict[str, Any] = {
        "type": "progress",
        "progress": min(1.0, max(0.0, float(progress))),
        "stage": stage[:128],
    }
    if message:
        value["message"] = message[:2048]
    emit(value)


def runtime_root() -> Path:
    override = os.environ.get("SENSITIVE_CONTENT_RUNTIME_ROOT", "").strip()
    if override:
        return Path(override).resolve()
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent.parent
    return Path(__file__).resolve().parents[1]


def load_calibration(root: Path) -> dict[str, Any]:
    path = root / "config" / "calibration.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise WorkerError(f"Calibration is unavailable or invalid: {error}") from error
    if value.get("schemaVersion") != SCHEMA_VERSION:
        raise WorkerError("Calibration schemaVersion is unsupported.")
    profiles = value.get("profiles")
    if not isinstance(profiles, dict) or any(name not in profiles for name in SUPPORTED_SENSITIVITY):
        raise WorkerError("Calibration sensitivity profiles are incomplete.")
    return value


def finite_number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise WorkerError(f"{name} must be a number.")
    result = float(value)
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise WorkerError(f"{name} is outside its supported range.")
    return result


def parse_request(line: str) -> AnalysisRequest:
    try:
        value = json.loads(line)
    except json.JSONDecodeError as error:
        raise WorkerError(f"Analysis request JSON is invalid: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA_VERSION:
        raise WorkerError("Analysis request schemaVersion is unsupported.")
    source_raw = value.get("sourcePath")
    if not isinstance(source_raw, str) or not source_raw.strip():
        raise WorkerError("Analysis request sourcePath is missing.")
    source = Path(source_raw).resolve()
    if not source.is_file():
        raise WorkerError(f"Source video is unavailable: {source}")
    duration = finite_number(value.get("sourceDuration"), "sourceDuration", 0.001, 30 * 24 * 3600)
    fps = finite_number(value.get("sourceFps"), "sourceFps", 0.01, 1000.0)
    raw_categories = value.get("categories")
    if not isinstance(raw_categories, dict):
        raise WorkerError("Analysis request categories are missing.")
    categories = {
        category: raw_categories.get(category) is True for category in SUPPORTED_CATEGORIES
    }
    if not any(categories.values()):
        raise WorkerError("At least one sensitive-content category must be enabled.")
    sensitivity = value.get("sensitivity")
    if sensitivity not in SUPPORTED_SENSITIVITY:
        raise WorkerError("Analysis request sensitivity is unsupported.")
    return AnalysisRequest(source, duration, fps, categories, sensitivity)


def resolve_ffmpeg() -> str:
    configured = os.environ.get("DOWNLOAD_MULTI_PLATFORM_FFMPEG", "").strip()
    if configured:
        path = Path(configured)
        if path.is_file():
            return str(path)
        raise WorkerError(f"Managed FFmpeg is unavailable: {path}")
    discovered = shutil.which("ffmpeg")
    if discovered:
        return discovered
    raise WorkerError(
        "Managed FFmpeg path was not provided. Reinstall or repair the FFmpeg runtime."
    )


def session(path: Path) -> ort.InferenceSession:
    if not path.is_file():
        raise WorkerError(f"Required model is unavailable: {path.name}")
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.enable_mem_pattern = True
    options.log_severity_level = 3
    cpu_count = max(1, os.cpu_count() or 1)
    options.intra_op_num_threads = max(1, min(4, cpu_count))
    options.inter_op_num_threads = 1
    try:
        return ort.InferenceSession(
            str(path),
            sess_options=options,
            providers=["CPUExecutionProvider"],
        )
    except Exception as error:
        raise WorkerError(f"Could not load model {path.name}: {error}") from error


def read_exact(stream: Any, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def drain_stderr(stream: Any, output: bytearray) -> None:
    while True:
        chunk = stream.read(8192)
        if not chunk:
            return
        output.extend(chunk)
        if len(output) > MAX_STDERR_BYTES:
            del output[: len(output) - MAX_STDERR_BYTES]


def ffmpeg_decode_command(
    ffmpeg: str,
    source: Path,
    fps: float,
    start: float,
    end: float,
) -> list[str]:
    duration = max(0.0, end - start)
    filter_graph = (
        f"fps={fps:.8f},"
        f"scale={FRAME_SIZE}:{FRAME_SIZE}:force_original_aspect_ratio=decrease,"
        f"pad={FRAME_SIZE}:{FRAME_SIZE}:(ow-iw)/2:(oh-ih)/2:black"
    )
    return [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        f"{start:.9f}",
        "-i",
        str(source),
        "-t",
        f"{duration:.9f}",
        "-map",
        "0:v:0",
        "-an",
        "-sn",
        "-dn",
        "-vf",
        filter_graph,
        "-pix_fmt",
        "rgb24",
        "-f",
        "rawvideo",
        "pipe:1",
    ]


def decoded_frames(
    ffmpeg: str,
    source: Path,
    fps: float,
    start: float,
    end: float,
) -> Iterator[tuple[float, np.ndarray]]:
    duration = max(0.0, end - start)
    if duration <= 0:
        return
    command = ffmpeg_decode_command(ffmpeg, source, fps, start, end)
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=CREATE_NO_WINDOW,
    )
    assert process.stdout is not None
    assert process.stderr is not None
    stderr = bytearray()
    stderr_thread = threading.Thread(
        target=drain_stderr, args=(process.stderr, stderr), daemon=True
    )
    stderr_thread.start()
    frame_index = 0
    try:
        while True:
            payload = read_exact(process.stdout, FRAME_BYTES)
            if not payload:
                break
            if len(payload) != FRAME_BYTES:
                raise WorkerError("FFmpeg returned a truncated analysis frame.")
            frame = np.frombuffer(payload, dtype=np.uint8).reshape(
                FRAME_SIZE, FRAME_SIZE, 3
            )
            timestamp = min(end, start + frame_index / fps)
            yield timestamp, frame
            frame_index += 1
    except BaseException:
        process.kill()
        process.wait()
        raise
    finally:
        process.stdout.close()
    status = process.wait()
    stderr_thread.join(timeout=2)
    if status != 0:
        detail = bytes(stderr).decode("utf-8", errors="replace").strip()
        raise WorkerError(
            f"FFmpeg analysis decode failed with exit code {status}"
            + (f": {detail}" if detail else ".")
        )


def sigmoid(values: np.ndarray) -> np.ndarray:
    clipped = np.clip(values, -50.0, 50.0)
    return 1.0 / (1.0 + np.exp(-clipped))


def softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - values.max(axis=-1, keepdims=True)
    exponent = np.exp(shifted)
    return exponent / exponent.sum(axis=-1, keepdims=True)


def normalized_evidence(value: float, floor: float, full_scale: float) -> float:
    if full_scale <= floor:
        raise WorkerError("Blood-gore evidence calibration is invalid.")
    return float(np.clip((value - floor) / (full_scale - floor), 0.0, 1.0))


def blood_color_evidence(frame: np.ndarray, calibration: dict[str, Any]) -> float:
    pixels = np.asarray(frame, dtype=np.float32)
    if pixels.shape != (FRAME_SIZE, FRAME_SIZE, 3):
        raise WorkerError("Blood-gore color analysis received an invalid frame.")
    red = pixels[:, :, 0]
    green = pixels[:, :, 1]
    blue = pixels[:, :, 2]
    mask = (
        (red >= float(calibration["redMinimum"]))
        & (red <= float(calibration["redMaximum"]))
        & (green <= float(calibration["greenMaximum"]))
        & (blue <= float(calibration["blueMaximum"]))
        & (
            red
            >= green * float(calibration["redToGreenRatio"])
            + float(calibration["redGreenOffset"])
        )
        & (
            red
            >= blue * float(calibration["redToBlueRatio"])
            + float(calibration["redBlueOffset"])
        )
        & ((red - green) >= float(calibration["redGreenDifference"]))
    )
    grid = int(calibration["localGrid"])
    if grid < 1 or FRAME_SIZE % grid != 0:
        raise WorkerError("Blood-gore local-grid calibration is invalid.")
    block = FRAME_SIZE // grid
    local_ratios = mask.reshape(grid, block, grid, block).mean(axis=(1, 3))
    local_ratio = float(local_ratios.max())
    global_ratio = float(mask.mean())
    active_cells = int(
        np.count_nonzero(
            local_ratios >= float(calibration["activeLocalRatioFloor"])
        )
    )
    if (
        global_ratio > float(calibration["maximumGlobalRatio"])
        or active_cells > int(calibration["maximumActiveLocalCells"])
    ):
        return 0.0
    global_score = normalized_evidence(
        global_ratio,
        float(calibration["globalRatioFloor"]),
        float(calibration["globalRatioFullScale"]),
    )
    local_score = normalized_evidence(
        local_ratio,
        float(calibration["localRatioFloor"]),
        float(calibration["localRatioFullScale"]),
    )
    return math.sqrt(global_score * local_score)


def temporal_blood_color_evidence(
    values: Iterable[float], calibration: dict[str, Any]
) -> float:
    evidence = [
        float(value)
        for value in values
        if float(value) >= float(calibration["temporalEvidenceFloor"])
    ]
    minimum_frames = int(calibration["temporalMinimumEvidenceFrames"])
    if minimum_frames < 1:
        raise WorkerError("Blood-gore temporal evidence calibration is invalid.")
    if len(evidence) < minimum_frames:
        return 0.0
    return max(evidence)


def blood_candidate_hit(
    values: dict[str, float],
    profile: dict[str, Any],
    generic_threshold: float,
) -> bool:
    return (
        values["blood_gore"] >= generic_threshold
        or values["_violence_static"]
        >= float(profile["bloodCandidateViolenceThreshold"])
        or values["_blood_color"]
        >= float(profile["bloodColorCandidateThreshold"])
    )


def fused_blood_gore_score(
    values: dict[str, float],
    profile: dict[str, Any],
    temporal_context: float = 0.0,
) -> float:
    base = float(values["blood_gore"])
    context = max(float(values["_violence_static"]), float(temporal_context))
    if context < float(profile["bloodContextThreshold"]):
        return base
    color = float(values["_blood_color"])
    nsfl_scale = float(profile["bloodNsflAssistScale"])
    if nsfl_scale <= 0.0:
        raise WorkerError("Blood-gore NSFL assist calibration is invalid.")
    nsfl_evidence = min(1.0, base / nsfl_scale)
    return max(
        base,
        math.sqrt(max(0.0, color) * context),
        math.sqrt(max(0.0, nsfl_evidence) * context),
    )


class Models:
    def __init__(
        self,
        root: Path,
        categories: dict[str, bool],
        calibration: dict[str, Any] | None = None,
    ) -> None:
        model_root = root / "models"
        self.blood_enabled = categories["blood_gore"]
        self.blood_calibration = (
            calibration["bloodGoreFusion"] if self.blood_enabled and calibration else None
        )
        self.safety = (
            session(model_root / "image-safety-classifier-xs.onnx")
            if categories["adult_nudity"] or categories["blood_gore"]
            else None
        )
        self.multi = (
            session(model_root / "image-multi-detect.onnx")
            if (
                categories["adult_nudity"]
                or categories["blood_gore"]
                or categories["violence_weapons"]
            )
            else None
        )
        self.temporal = (
            session(model_root / "aleris-violence-temporal.onnx")
            if categories["blood_gore"] or categories["violence_weapons"]
            else None
        )

    def blood_color_score(self, frame: np.ndarray) -> float:
        if not self.blood_enabled:
            return 0.0
        if self.blood_calibration is None:
            raise WorkerError("Blood-gore fusion calibration is unavailable.")
        return blood_color_evidence(frame, self.blood_calibration)

    def static_scores(self, frames: list[np.ndarray]) -> list[dict[str, float]]:
        if not frames:
            return []
        pixels = np.stack(frames).astype(np.float32)
        nchw_255 = pixels.transpose(0, 3, 1, 2)
        safety_probabilities: np.ndarray | None = None
        if self.safety is not None:
            safety_probabilities = self.safety.run(
                None, {self.safety.get_inputs()[0].name: nchw_255}
            )[0]
        multi_probabilities: np.ndarray | None = None
        if self.multi is not None:
            normalized = nchw_255 / 255.0
            mean = np.asarray([0.485, 0.456, 0.406], dtype=np.float32)[
                None, :, None, None
            ]
            std = np.asarray([0.229, 0.224, 0.225], dtype=np.float32)[
                None, :, None, None
            ]
            normalized = (normalized - mean) / std
            multi_logits = self.multi.run(
                None, {self.multi.get_inputs()[0].name: normalized}
            )[0]
            multi_probabilities = sigmoid(np.asarray(multi_logits, dtype=np.float32))
        results: list[dict[str, float]] = []
        for index in range(len(frames)):
            safety = (
                np.asarray(safety_probabilities[index], dtype=np.float32)
                if safety_probabilities is not None
                else np.zeros(3, dtype=np.float32)
            )
            multi = (
                multi_probabilities[index]
                if multi_probabilities is not None
                else np.zeros(8, dtype=np.float32)
            )
            results.append(
                {
                    "adult_nudity": float(max(safety[1], multi[0])),
                    "blood_gore": float(safety[0]),
                    "violence_weapons": float(max(multi[1], multi[2])),
                    "_blood_color": self.blood_color_score(frames[index]),
                    "_violence_static": float(max(multi[1], multi[2])),
                }
            )
        return results

    def temporal_score(self, frames: Iterable[np.ndarray]) -> float:
        if self.temporal is None:
            return 0.0
        pixels = np.stack(tuple(frames)).astype(np.float32) / 255.0
        btchw = pixels.transpose(0, 3, 1, 2)[None, ...]
        mean = np.asarray([0.45, 0.45, 0.45], dtype=np.float32)[None, None, :, None, None]
        std = np.asarray([0.225, 0.225, 0.225], dtype=np.float32)[
            None, None, :, None, None
        ]
        normalized = (btchw - mean) / std
        logits = self.temporal.run(
            None, {self.temporal.get_inputs()[0].name: normalized}
        )[0]
        return float(softmax(np.asarray(logits, dtype=np.float32))[0, 1])


def merge_ranges(
    ranges: list[tuple[float, float]], duration: float
) -> list[tuple[float, float]]:
    normalized = sorted(
        (max(0.0, start), min(duration, end))
        for start, end in ranges
        if end > start
    )
    merged: list[tuple[float, float]] = []
    for start, end in normalized:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def coarse_scan(
    request: AnalysisRequest,
    calibration: dict[str, Any],
    models: Models,
    ffmpeg: str,
) -> list[tuple[float, float]]:
    fps = finite_number(calibration.get("coarseFps"), "coarseFps", 0.1, 10.0)
    padding = finite_number(
        calibration.get("refinePaddingSeconds"),
        "refinePaddingSeconds",
        0.0,
        60.0,
    )
    batch_size = int(
        finite_number(calibration.get("staticBatchSize"), "staticBatchSize", 1, 256)
    )
    threshold = float(
        calibration["profiles"][request.sensitivity]["candidateThreshold"]
    )
    profile = calibration["profiles"][request.sensitivity]
    expected = max(1, int(math.ceil(request.source_duration * fps)))
    frames: list[np.ndarray] = []
    timestamps: list[float] = []
    candidates: list[tuple[float, float]] = []
    processed = 0

    def flush() -> None:
        nonlocal processed
        scores = models.static_scores(frames)
        for timestamp, values in zip(timestamps, scores, strict=True):
            if any(
                request.categories[category]
                and (
                    blood_candidate_hit(values, profile, threshold)
                    if category == "blood_gore"
                    else values[category] >= threshold
                )
                for category in SUPPORTED_CATEGORIES
            ):
                candidates.append(
                    (
                        timestamp - padding,
                        timestamp + (1.0 / fps) + padding,
                    )
                )
        processed += len(frames)
        frames.clear()
        timestamps.clear()
        emit_progress(
            0.08 + 0.44 * min(1.0, processed / expected),
            "coarse_scan",
            f"Scanned {min(request.source_duration, processed / fps):.1f}s",
        )

    for timestamp, frame in decoded_frames(
        ffmpeg, request.source_path, fps, 0.0, request.source_duration
    ):
        timestamps.append(timestamp)
        frames.append(frame)
        if len(frames) >= batch_size:
            flush()
    if frames:
        flush()
    ranges = merge_ranges(candidates, request.source_duration)
    maximum_ranges = int(
        finite_number(
            calibration.get("maxCandidateRanges"), "maxCandidateRanges", 1, 100000
        )
    )
    if len(ranges) > maximum_ranges:
        raise WorkerError("Coarse scan produced too many candidate ranges.")
    coverage = sum(end - start for start, end in ranges)
    maximum_coverage = finite_number(
        calibration.get("maxCandidateCoverageRatio"),
        "maxCandidateCoverageRatio",
        0.01,
        1.0,
    )
    if coverage > request.source_duration * maximum_coverage:
        return [(0.0, request.source_duration)]
    return ranges


def refine_scan(
    request: AnalysisRequest,
    calibration: dict[str, Any],
    models: Models,
    ffmpeg: str,
    ranges: list[tuple[float, float]],
) -> list[Observation]:
    if not ranges:
        return []
    fps = finite_number(calibration.get("refineFps"), "refineFps", 1.0, 30.0)
    batch_size = int(
        finite_number(calibration.get("staticBatchSize"), "staticBatchSize", 1, 256)
    )
    window_size = int(
        finite_number(
            calibration.get("temporalWindowFrames"),
            "temporalWindowFrames",
            2,
            128,
        )
    )
    stride = int(
        finite_number(
            calibration.get("temporalStrideFrames"),
            "temporalStrideFrames",
            1,
            window_size,
        )
    )
    profile = calibration["profiles"][request.sensitivity]
    threshold = float(profile["triggerThreshold"])
    observations: list[Observation] = []
    coverage = max(0.001, sum(end - start for start, end in ranges))
    completed_coverage = 0.0
    for range_index, (start, end) in enumerate(ranges):
        static_frames: list[np.ndarray] = []
        static_times: list[float] = []
        temporal_frames: deque[np.ndarray] = deque(maxlen=window_size)
        temporal_blood_colors: deque[float] = deque(maxlen=window_size)
        frame_index = 0

        def flush_static() -> None:
            scores = models.static_scores(static_frames)
            for timestamp, values in zip(static_times, scores, strict=True):
                for category in SUPPORTED_CATEGORIES:
                    if not request.categories[category]:
                        continue
                    score = (
                        fused_blood_gore_score(values, profile)
                        if category == "blood_gore"
                        else values[category]
                    )
                    if score >= threshold:
                        observations.append(
                            Observation(
                                timestamp,
                                min(request.source_duration, timestamp + 1.0 / fps),
                                category,
                                score,
                            )
                        )
            static_frames.clear()
            static_times.clear()

        for timestamp, frame in decoded_frames(
            ffmpeg, request.source_path, fps, start, end
        ):
            static_frames.append(frame)
            static_times.append(timestamp)
            temporal_frames.append(frame)
            temporal_blood_colors.append(models.blood_color_score(frame))
            if (
                (
                    request.categories["blood_gore"]
                    or request.categories["violence_weapons"]
                )
                and len(temporal_frames) == window_size
                and (frame_index - window_size + 1) % stride == 0
            ):
                score = models.temporal_score(temporal_frames)
                window_start = max(start, timestamp - (window_size - 1) / fps)
                window_end = min(request.source_duration, timestamp + 1.0 / fps)
                if request.categories["violence_weapons"] and score >= threshold:
                    observations.append(
                        Observation(
                            window_start,
                            window_end,
                            "violence_weapons",
                            score,
                        )
                    )
                if request.categories["blood_gore"]:
                    blood_score = fused_blood_gore_score(
                        {
                            "blood_gore": 0.0,
                            "_blood_color": temporal_blood_color_evidence(
                                temporal_blood_colors,
                                models.blood_calibration,
                            ),
                            "_violence_static": 0.0,
                        },
                        profile,
                        temporal_context=score,
                    )
                    if blood_score >= threshold:
                        observations.append(
                            Observation(
                                window_start,
                                window_end,
                                "blood_gore",
                                blood_score,
                            )
                        )
            if len(static_frames) >= batch_size:
                flush_static()
            frame_index += 1
        if static_frames:
            flush_static()
        completed_coverage += end - start
        emit_progress(
            0.55 + 0.43 * min(1.0, completed_coverage / coverage),
            "refine_scan",
            f"Verified candidate {range_index + 1}/{len(ranges)}",
        )
    return observations


def observations_to_segments(
    observations: list[Observation],
    request: AnalysisRequest,
    calibration: dict[str, Any],
) -> list[dict[str, Any]]:
    if not observations:
        return []
    profile = calibration["profiles"][request.sensitivity]
    strong = float(profile["strongThreshold"])
    consecutive = int(profile["consecutiveHits"])
    refine_fps = float(calibration["refineFps"])
    category_segments: list[dict[str, Any]] = []
    for category in SUPPORTED_CATEGORIES:
        values = sorted(
            (value for value in observations if value.category == category),
            key=lambda value: (value.start, value.end),
        )
        group: list[Observation] = []

        def flush_group() -> None:
            if not group:
                return
            if len(group) >= consecutive or max(value.score for value in group) >= strong:
                category_segments.append(
                    {
                        "sourceStart": max(0.0, group[0].start),
                        "sourceEnd": min(
                            request.source_duration, max(value.end for value in group)
                        ),
                        "categories": [category],
                        "confidence": max(value.score for value in group),
                    }
                )
            group.clear()

        for value in values:
            if group and value.start > max(item.end for item in group) + 2.0 / refine_fps:
                flush_group()
            group.append(value)
        flush_group()
    category_segments.sort(key=lambda value: (value["sourceStart"], value["sourceEnd"]))
    merged: list[dict[str, Any]] = []
    for segment in category_segments:
        if merged and segment["sourceStart"] <= merged[-1]["sourceEnd"]:
            previous = merged[-1]
            previous["sourceEnd"] = max(previous["sourceEnd"], segment["sourceEnd"])
            previous["confidence"] = max(previous["confidence"], segment["confidence"])
            for category in segment["categories"]:
                if category not in previous["categories"]:
                    previous["categories"].append(category)
        else:
            merged.append(segment)
    maximum = int(
        finite_number(
            calibration.get("maxOutputSegments"), "maxOutputSegments", 1, 100000
        )
    )
    if len(merged) > maximum:
        raise WorkerError("Analysis produced too many sensitive-content segments.")
    return merged


def analyze(line: str) -> None:
    request = parse_request(line)
    root = runtime_root()
    calibration = load_calibration(root)
    emit_progress(0.02, "loading_models", "Loading local CPU inference sessions")
    models = Models(root, request.categories, calibration)
    ffmpeg = resolve_ffmpeg()
    emit_progress(0.06, "coarse_scan", "Scanning source video without audio")
    ranges = coarse_scan(request, calibration, models, ffmpeg)
    emit_progress(
        0.54,
        "candidate_merge",
        f"Found {len(ranges)} candidate ranges",
    )
    observations = refine_scan(request, calibration, models, ffmpeg, ranges)
    segments = observations_to_segments(observations, request, calibration)
    emit(
        {
            "type": "result",
            "result": {
                "provider": "cpu",
                "segments": segments,
            },
        }
    )


def main() -> int:
    configure_protocol_io()
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--health-json", action="store_true")
    parser.add_argument("--analyze-jsonl", action="store_true")
    args, unknown = parser.parse_known_args()
    if unknown or args.health_json == args.analyze_jsonl:
        sys.stderr.write(
            "Use exactly one command: --health-json or --analyze-jsonl.\n"
        )
        return 2
    if args.health_json:
        emit({"status": "ready", "schemaVersion": SCHEMA_VERSION})
        return 0
    line = sys.stdin.readline()
    if not line:
        emit({"type": "error", "message": "Analysis request JSONL is missing."})
        return 1
    try:
        analyze(line)
        return 0
    except WorkerError as error:
        emit({"type": "error", "message": str(error)})
        return 1
    except BaseException as error:
        emit(
            {
                "type": "error",
                "message": f"Sensitive-content worker failed unexpectedly: {error}",
            }
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
