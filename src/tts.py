"""Free neural-voice narration via edge-tts (no API key required).

Captures word-level timing directly from edge-tts's WordBoundary events
instead of re-transcribing the audio afterwards -- simpler and more
accurate than a separate speech-to-text pass.
"""
from __future__ import annotations

import asyncio
import re
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


def _normalize_for_tts(text: str) -> str:
    """Rewrites word-joining punctuation edge-tts's tokenizer would split on
    its own (em/en dashes glued to words with no surrounding space, e.g.
    "years—but") into a plain comma+space, so the whitespace-token count
    used for punctuation reattachment below stays aligned with the number
    of WordBoundary events edge-tts actually emits.
    """
    text = re.sub(r"\s*[—–]\s*", ", ", text)  # em dash, en dash (glued or spaced)
    # A plain hyphen used as a spaced aside ("mad - furious - so I left") is a
    # separate stand-alone token that gets no WordBoundary event of its own,
    # unlike a real compound word ("self-proclaimed", no surrounding spaces),
    # which is left untouched.
    text = re.sub(r"(?<=\S)\s+-\s+(?=\S)", ", ", text)
    return re.sub(r"\s+", " ", text).strip()


async def _synthesize(text: str, voice: str, rate: str, audio_path: str) -> list[WordTiming]:
    communicate = edge_tts.Communicate(text, voice=voice, rate=rate, boundary="WordBoundary")
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
    text = _normalize_for_tts(text)
    words = asyncio.run(_synthesize(text, voice, rate, audio_path))

    # edge-tts's WordBoundary events strip punctuation from `text` (it's the
    # bare spoken word) -- recover periods/question marks etc. for captions
    # by re-attaching the original whitespace-split tokens, which still
    # carry punctuation, matched up in the same order.
    tokens = text.split()
    if len(tokens) == len(words):
        for word, token in zip(words, tokens):
            word.text = token
    else:
        print(
            f"      WARNING: word count mismatch (text={len(tokens)}, "
            f"tts={len(words)}) -- captions will be missing punctuation this run"
        )

    duration = words[-1].end_s if words else 0.0
    return Narration(audio_path=audio_path, words=words, duration_s=duration)
