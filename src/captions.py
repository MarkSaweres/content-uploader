"""Builds a burned-in-style ASS subtitle file from word-level TTS timings,
grouped into short multi-word chunks (the "bouncing caption" look common
on Shorts/TikTok/Reels).
"""
from __future__ import annotations

from .tts import WordTiming

_HEADER_TEMPLATE = """[Script Info]
ScriptType: v4.00+
PlayResX: {width}
PlayResY: {height}
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,{font},{font_size},&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,5,2,2,60,60,{margin_v},1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def _fmt_time(seconds: float) -> str:
    cs = round(seconds * 100)
    h, rem = divmod(cs, 360000)
    m, rem = divmod(rem, 6000)
    s, cs = divmod(rem, 100)
    return f"{h:d}:{m:02d}:{s:02d}.{cs:02d}"


def build_ass(
    words: list[WordTiming],
    out_path: str,
    width: int,
    height: int,
    font: str,
    font_size: int,
    words_per_group: int = 4,
    margin_v: int = 260,
) -> str:
    lines = [
        _HEADER_TEMPLATE.format(
            width=width, height=height, font=font, font_size=font_size, margin_v=margin_v
        )
    ]
    for i in range(0, len(words), words_per_group):
        group = words[i : i + words_per_group]
        if not group:
            continue
        text = " ".join(w.text for w in group).upper()
        start = _fmt_time(group[0].start_s)
        end = _fmt_time(group[-1].end_s)
        lines.append(f"Dialogue: 0,{start},{end},Default,,0,0,0,,{text}\n")

    with open(out_path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    return out_path
