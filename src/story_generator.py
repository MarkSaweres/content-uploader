"""Generates an original short "Reddit story" style script using Groq's
free-tier, OpenAI-compatible chat completions API.

Get a free API key at https://console.groq.com/keys — no payment method
required for the free tier at the time of writing.
"""
from __future__ import annotations

import random
from dataclasses import dataclass

import requests

GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
GROQ_MODEL = "llama-3.3-70b-versatile"

SYSTEM_PROMPT = (
    "You write short, original, PG-13 fictional stories in the style of "
    "viral Reddit posts, meant to be narrated aloud in under 45 seconds. "
    "Never reuse or paraphrase a real Reddit post — invent everything. "
    "Output ONLY the story body: no title, no subreddit tag, no markdown, "
    "no quotation marks around the whole thing, no meta commentary."
)


@dataclass
class Story:
    theme_id: str
    theme_label: str
    text: str
    search_keywords: list[str]


def pick_theme(themes: list[dict], rng: random.Random | None = None) -> dict:
    rng = rng or random
    return rng.choice(themes)


def generate_story(api_key: str, theme: dict, timeout: int = 30) -> Story:
    resp = requests.post(
        GROQ_URL,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": GROQ_MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": theme["prompt"]},
            ],
            "temperature": 1.0,
            "max_tokens": 400,
        },
        timeout=timeout,
    )
    resp.raise_for_status()
    data = resp.json()
    text = data["choices"][0]["message"]["content"].strip().strip('"')
    return Story(
        theme_id=theme["id"],
        theme_label=theme["label"],
        text=text,
        search_keywords=theme.get("search_keywords", []),
    )
