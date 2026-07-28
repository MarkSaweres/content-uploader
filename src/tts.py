"""Free neural-voice narration via edge-tts (no API key required).

Captures word-level timing directly from edge-tts's WordBoundary events
instead of re-transcribing the audio afterwards -- simpler and more
accurate than a separate speech-to-text pass.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass

import edge_tts


@dataclass
class WordTiming:
    text: str
    start_s: float
    end_s: float


@dataclass
class Narration:
    audio_path: str
    words: list[WordTiming]
    duration_s: float


async def _synthesize(text: str, voice: str, rate: str, audio_path: str) -> list[WordTiming]:
    communicate = edge_tts.Communicate(text, voice=voice, rate=rate)
    words: list[WordTiming] = []
    with open(audio_path, "wb") as audio_file:
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio_file.write(chunk["data"])
            elif chunk["type"] == "WordBoundary":
                start = chunk["offset"] / 1e7  # 100-ns units -> seconds
                dur = chunk["duration"] / 1e7
                words.append(WordTiming(text=chunk["text"], start_s=start, end_s=start + dur))
    return words


def generate_narration(text: str, voice: str, rate: str, audio_path: str) -> Narration:
    words = asyncio.run(_synthesize(text, voice, rate, audio_path))
    duration = words[-1].end_s if words else 0.0
    return Narration(audio_path=audio_path, words=words, duration_s=duration)
