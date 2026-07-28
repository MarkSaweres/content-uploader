"""Assembles the final vertical short with ffmpeg: looped/cropped
background footage + narration audio + burned-in captions.
"""
from __future__ import annotations

import json
import subprocess


def probe_duration(path: str) -> float:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            path,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(json.loads(result.stdout)["format"]["duration"])


def _escape_filter_path(path: str) -> str:
    return path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")


def build_short(
    background_path: str,
    narration_path: str,
    ass_path: str,
    out_path: str,
    duration_s: float,
    width: int = 1080,
    height: int = 1920,
    fps: int = 30,
) -> str:
    ass_escaped = _escape_filter_path(ass_path)
    filter_complex = (
        f"[0:v]scale={width}:{height}:force_original_aspect_ratio=increase,"
        f"crop={width}:{height},setsar=1,fps={fps},ass='{ass_escaped}'[v]"
    )
    cmd = [
        "ffmpeg",
        "-y",
        "-stream_loop",
        "-1",
        "-i",
        background_path,
        "-i",
        narration_path,
        "-filter_complex",
        filter_complex,
        "-map",
        "[v]",
        "-map",
        "1:a",
        "-t",
        f"{duration_s:.2f}",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "20",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-movflags",
        "+faststart",
        out_path,
    ]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    return out_path
