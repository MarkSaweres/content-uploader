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
# Groq deprecates/renames models fairly often -- if this starts 404ing again,
# check https://console.groq.com/docs/models for the current production id.
GROQ_MODEL = "openai/gpt-oss-120b"

SYSTEM_PROMPT = (
    "You write short, original, PG-13 fictional stories in the style of the "
    "most viral posts on Reddit's storytelling subreddits, meant to be "
    "narrated aloud in under 45 seconds to someone with zero context. Every "
    "story must: open with a punchy one-sentence hook that states the "
    "conflict in plain, immediately understandable terms (no throat-"
    "clearing or scene-setting first); center on ONE clear, genuinely "
    "divisive, morally gray conflict with real stakes -- not mundane, but "
    "also not cluttered with sub-plots or odd specific details that take "
    "effort to parse; be told in plain chronological order a stranger can "
    "follow on a single listen; and end on a cliffhanger or a direct "
    "question to the listener so people argue about it in the comments. "
    "If a real post title is given as inspiration, use ONLY its general "
    "scenario -- never copy its wording, and never reuse or paraphrase any "
    "other real Reddit post from memory; invent every specific detail "
    "yourself. Never target real people, real brands, or protected groups, "
    "and no slurs, hate speech, or graphic violence/sexual content -- the "
    "goal is dramatic, clear, and polarizing, not hateful, explicit, or "
    "confusing. Each prompt gives you a specific setting/premise -- use "
    "exactly that, and resist adding extra embellishments or twists beyond "
    "what's needed to tell ONE clean conflict. Do not default to a coffee "
    "shop, cafe, or barista scenario unless the given setting explicitly is "
    "one. Output ONLY the story body: no title, no subreddit tag, no "
    "markdown, no quotation marks around the whole thing, no meta "
    "commentary."
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


def pick_setting(theme: dict, rng: random.Random | None = None) -> str:
    rng = rng or random
    settings = theme.get("settings") or []
    return rng.choice(settings) if settings else ""


def generate_story(
    api_key: str, theme: dict, setting: str = "", premise: str = "", timeout: int = 30
) -> Story:
    user_content = theme["prompt"]
    if premise:
        user_content = (
            "Inspired by a real post title (use ONLY its general scenario -- "
            "do not copy its wording or reuse it verbatim; invent your own "
            f'original story around this premise): "{premise}"\n\n{user_content}'
        )
    elif setting:
        user_content = f"Setting for this story: {setting}.\n\n{user_content}"
    resp = requests.post(
        GROQ_URL,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": GROQ_MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_content},
            ],
            "temperature": 1.0,
            "max_completion_tokens": 400,
            "reasoning_effort": "low",
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
