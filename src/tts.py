"""Free neural-voice narration via edge-tts (no API key required).

Captures word-level timing directly from edge-tts's WordBoundary events
instead of re-transcribing the audio afterwards -- simpler and more
accurate than a separate speech-to-text pass.
"""
from __future__ import annotations

import asyncio
import difflib
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


def _normalize_token(tok: str) -> str:
    return re.sub(r"[^0-9a-zA-Z]", "", tok).lower()


def _reattach_punctuation(words: list[WordTiming], text: str) -> None:
    """Best-effort re-attach of the original punctuated tokens onto each
    WordTiming (whose .text is edge-tts's bare, punctuation-stripped spoken
    word). Uses sequence alignment instead of a strict 1:1 zip, because
    edge-tts's own tokenizer doesn't always produce the same word count as
    a plain whitespace split -- e.g. "$500" can become three spoken words
    ("five", "hundred", "dollars"), or some other punctuation mark ends up
    as its own stray token. An exact-length check loses punctuation for the
    *entire* story on any of these, which happens often enough to matter.
    """
    if not words:
        return
    tokens = text.split()
    tts_norm = [_normalize_token(w.text) for w in words]
    text_norm = [_normalize_token(t) for t in tokens]

    matcher = difflib.SequenceMatcher(a=tts_norm, b=text_norm, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                words[i1 + k].text = tokens[j1 + k]
        elif tag == "replace":
            n = min(i2 - i1, j2 - j1)
            for k in range(n):
                words[i1 + k].text = tokens[j1 + k]
            if j2 - j1 > n:
                extra = " ".join(tokens[j1 + n : j2])
                target = i1 + n - 1 if n > 0 else i1 - 1
                if 0 <= target < len(words):
                    words[target].text = f"{words[target].text} {extra}".strip()
        elif tag == "insert":
            # Text has token(s) (usually stray punctuation) with no TTS
            # boundary of their own -- fold them onto the previous word.
            extra = " ".join(tokens[j1:j2])
            target = i1 - 1
            if 0 <= target < len(words):
                words[target].text = f"{words[target].text} {extra}".strip()
        # "delete": TTS boundary(ies) with no corresponding text token (e.g.
        # a number expanded into several spoken words) -- nothing to
        # reattach, leave the bare TTS text as-is for those.


def generate_narration(text: str, voice: str, rate: str, audio_path: str) -> Narration:
    text = _normalize_for_tts(text)
    words = asyncio.run(_synthesize(text, voice, rate, audio_path))

    tokens = text.split()
    if len(tokens) != len(words):
        print(
            f"      NOTE: TTS word count differs from text ({len(tokens)} vs "
            f"{len(words)}) -- reattaching punctuation via alignment"
        )
    _reattach_punctuation(words, text)

    duration = words[-1].end_s if words else 0.0
    return Narration(audio_path=audio_path, words=words, duration_s=duration)
