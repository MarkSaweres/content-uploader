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
    background_paths: list[str],
    narration_path: str,
    ass_path: str,
    out_path: str,
    duration_s: float,
    width: int = 1080,
    height: int = 1920,
    fps: int = 30,
) -> str:
    """Cuts between each clip in `background_paths` (equal-length segments
    covering `duration_s` total) instead of looping a single clip, then
    burns in captions and muxes the narration audio over the result.
    """
    n = len(background_paths)
    segment_length = duration_s / n
    ass_escaped = _escape_filter_path(ass_path)

    filter_parts = [
        f"[{i}:v]scale={width}:{height}:force_original_aspect_ratio=increase,"
        f"crop={width}:{height},setsar=1,fps={fps},trim=duration={segment_length:.3f},"
        f"setpts=PTS-STARTPTS[seg{i}]"
        for i in range(n)
    ]
    concat_inputs = "".join(f"[seg{i}]" for i in range(n))
    filter_parts.append(f"{concat_inputs}concat=n={n}:v=1:a=0[bg]")
    filter_parts.append(f"[bg]ass='{ass_escaped}'[v]")
    filter_complex = ";".join(filter_parts)

    cmd = ["ffmpeg", "-y"]
    for path in background_paths:
        cmd += ["-stream_loop", "-1", "-i", path]
    cmd += ["-i", narration_path]

    cmd += [
        "-filter_complex",
        filter_complex,
        "-map",
        "[v]",
        "-map",
        f"{n}:a",
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
