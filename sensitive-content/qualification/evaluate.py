from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


DOMAINS = ("live_action", "animation_game", "medical", "news", "sports")
PROFILES = ("sensitive", "balanced", "low_false_positive")
CATEGORIES = ("adult_nudity", "blood_gore", "violence_weapons")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_segments(
    segments: Iterable[dict[str, Any]], duration: float, category: str | None = None
) -> list[tuple[float, float]]:
    values: list[tuple[float, float]] = []
    for segment in segments:
        categories = segment.get("categories", [])
        if category is not None and category not in categories:
            continue
        start = float(segment.get("sourceStart", segment.get("start", -1)))
        end = float(segment.get("sourceEnd", segment.get("end", -1)))
        if (
            not math.isfinite(start)
            or not math.isfinite(end)
            or start < 0
            or end <= start
        ):
            raise ValueError("Dataset contains an invalid segment.")
        values.append((max(0.0, start), min(duration, end)))
    values.sort()
    merged: list[tuple[float, float]] = []
    for start, end in values:
        if end <= start:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def interval_seconds(intervals: Iterable[tuple[float, float]]) -> float:
    return sum(end - start for start, end in intervals)


def intersection_seconds(
    left: list[tuple[float, float]], right: list[tuple[float, float]]
) -> float:
    total = 0.0
    left_index = 0
    right_index = 0
    while left_index < len(left) and right_index < len(right):
        left_start, left_end = left[left_index]
        right_start, right_end = right[right_index]
        total += max(0.0, min(left_end, right_end) - max(left_start, right_start))
        if left_end <= right_end:
            left_index += 1
        else:
            right_index += 1
    return total


def percentile95(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, math.ceil(0.95 * len(ordered)) - 1)
    return ordered[index]


def metric_accumulator() -> dict[str, Any]:
    return {
        "duration": 0.0,
        "groundTruthSeconds": 0.0,
        "predictedSeconds": 0.0,
        "intersectionSeconds": 0.0,
        "events": 0,
        "missedEvents": 0,
        "boundaryLead": [],
        "boundaryLag": [],
    }


def add_metrics(
    accumulator: dict[str, Any],
    ground_truth: list[tuple[float, float]],
    predicted: list[tuple[float, float]],
    duration: float,
) -> None:
    accumulator["duration"] += duration
    accumulator["groundTruthSeconds"] += interval_seconds(ground_truth)
    accumulator["predictedSeconds"] += interval_seconds(predicted)
    accumulator["intersectionSeconds"] += intersection_seconds(ground_truth, predicted)
    accumulator["events"] += len(ground_truth)
    for truth_start, truth_end in ground_truth:
        overlaps = [
            (start, end)
            for start, end in predicted
            if start < truth_end and end > truth_start
        ]
        if not overlaps:
            accumulator["missedEvents"] += 1
            continue
        best = max(
            overlaps,
            key=lambda value: min(value[1], truth_end) - max(value[0], truth_start),
        )
        accumulator["boundaryLead"].append(max(0.0, truth_start - best[0]))
        accumulator["boundaryLag"].append(max(0.0, best[1] - truth_end))


def finalize_metrics(accumulator: dict[str, Any]) -> dict[str, float]:
    truth = accumulator["groundTruthSeconds"]
    predicted = accumulator["predictedSeconds"]
    intersection = accumulator["intersectionSeconds"]
    duration = accumulator["duration"]
    events = accumulator["events"]
    false_positive = max(0.0, predicted - intersection)
    return {
        "segmentPrecision": intersection / predicted if predicted > 0 else 1.0,
        "segmentRecall": intersection / truth if truth > 0 else 1.0,
        "falsePositiveMinutesPerHour": false_positive * 60.0 / duration
        if duration > 0
        else 0.0,
        "falseNegativeEventRate": accumulator["missedEvents"] / events
        if events > 0
        else 0.0,
        "boundaryLeadSecondsP95": percentile95(accumulator["boundaryLead"]),
        "boundaryLagSecondsP95": percentile95(accumulator["boundaryLag"]),
    }


def load_index(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8-sig") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"Invalid JSONL at line {line_number}: {error}") from error
            if value.get("domain") not in DOMAINS:
                raise ValueError(f"Invalid domain at line {line_number}.")
            records.append(value)
    if not records:
        raise ValueError("Qualification dataset index is empty.")
    return records


def analyze(
    worker: Path,
    runtime_root: Path,
    ffmpeg: Path,
    record: dict[str, Any],
    profile: str,
    timeout_multiplier: float,
) -> list[dict[str, Any]]:
    source = Path(record["sourcePath"]).resolve()
    request = {
        "schemaVersion": 1,
        "sourcePath": str(source),
        "sourceDuration": float(record["sourceDuration"]),
        "sourceFps": float(record["sourceFps"]),
        "categories": {category: True for category in CATEGORIES},
        "sensitivity": profile,
    }
    environment = os.environ.copy()
    environment["SENSITIVE_CONTENT_RUNTIME_ROOT"] = str(runtime_root)
    environment["DOWNLOAD_MULTI_PLATFORM_FFMPEG"] = str(ffmpeg)
    timeout = max(120.0, float(record["sourceDuration"]) * timeout_multiplier)
    completed = subprocess.run(
        [str(worker), "--analyze-jsonl"],
        input=json.dumps(request, separators=(",", ":")) + "\n",
        text=True,
        capture_output=True,
        timeout=timeout,
        env=environment,
        creationflags=0x08000000 if os.name == "nt" else 0,
        check=False,
    )
    messages = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    terminals = [value for value in messages if value.get("type") in ("result", "error")]
    if completed.returncode != 0 or len(terminals) != 1 or terminals[0]["type"] != "result":
        detail = completed.stderr.strip() or (
            terminals[0].get("message") if terminals else "missing terminal result"
        )
        raise RuntimeError(f"Qualification analysis failed for {source}: {detail}")
    return terminals[0]["result"].get("segments", [])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--runtime-root", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--dataset-index", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout-multiplier", type=float, default=10.0)
    args = parser.parse_args()

    records = load_index(args.dataset_index)
    domains: dict[str, int] = {domain: 0 for domain in DOMAINS}
    accumulators: dict[str, dict[str, dict[str, Any]]] = {}
    for profile in PROFILES:
        accumulators[profile] = {"all": metric_accumulator()}
        for category in CATEGORIES:
            accumulators[profile][category] = metric_accumulator()

    verified_sources: list[dict[str, str]] = []
    for record_index, record in enumerate(records, 1):
        source = Path(record["sourcePath"]).resolve()
        if not source.is_file():
            raise ValueError(f"Qualification source is unavailable: {source}")
        expected_hash = str(record.get("sourceSha256", "")).lower()
        actual_hash = sha256_file(source)
        if expected_hash != actual_hash:
            raise ValueError(f"Qualification source SHA-256 mismatch: {source}")
        duration = float(record["sourceDuration"])
        if not math.isfinite(duration) or duration <= 0:
            raise ValueError(f"Qualification duration is invalid: {source}")
        domains[record["domain"]] += 1
        verified_sources.append({"path": str(source), "sha256": actual_hash})
        for profile in PROFILES:
            print(
                f"[{record_index}/{len(records)}] {profile}: {source.name}",
                file=sys.stderr,
                flush=True,
            )
            predicted_raw = analyze(
                args.worker,
                args.runtime_root,
                args.ffmpeg,
                record,
                profile,
                args.timeout_multiplier,
            )
            truth_raw = record.get("segments", [])
            for category in (None, *CATEGORIES):
                key = category or "all"
                truth = normalize_segments(truth_raw, duration, category)
                predicted = normalize_segments(predicted_raw, duration, category)
                add_metrics(accumulators[profile][key], truth, predicted, duration)

    output = {
        "schemaVersion": 1,
        "datasetIndexSha256": sha256_file(args.dataset_index),
        "domains": domains,
        "sources": verified_sources,
        "profiles": {
            profile: {
                key: finalize_metrics(accumulator)
                for key, accumulator in accumulators[profile].items()
            }
            for profile in PROFILES
        },
        "releaseGatePassed": False,
        "note": "Metrics do not approve data/model rights or the production release gate.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
