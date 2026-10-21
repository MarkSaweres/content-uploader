"""Fetches real post TITLES (not body text) from Reddit's public, logged-out
JSON endpoint, to use as inspiration for an LLM-written original story.
Never reproduces anyone's actual written post -- only the short title, which
the LLM then writes a completely original story around.

Uses the unauthenticated `https://www.reddit.com/r/<sub>/top.json` endpoint
(no API key/app registration needed) at very low volume (one request per
video). If Reddit ever blocks or rate-limits this -- which can happen from
shared cloud IPs like GitHub Actions runners even when it works fine from a
home connection -- this fails soft (returns None) rather than breaking the
pipeline; the caller falls back to the curated settings list instead.
"""
from __future__ import annotations

import random

import requests

USER_AGENT = "content-uploader/1.0 (personal hobby project; ~1 request/day)"
MIN_TITLE_LEN = 20


def fetch_premise(
    subreddit: str,
    timeframe: str = "week",
    limit: int = 25,
    rng: random.Random | None = None,
    timeout: int = 15,
) -> str | None:
    rng = rng or random
    url = f"https://www.reddit.com/r/{subreddit}/top.json"
    try:
        resp = requests.get(
            url,
            headers={"User-Agent": USER_AGENT},
            params={"limit": limit, "t": timeframe},
            timeout=timeout,
        )
        resp.raise_for_status()
        posts = resp.json()["data"]["children"]
    except (requests.RequestException, KeyError, ValueError, TypeError):
        return None

    titles = []
    for post in posts:
        data = post.get("data", {})
        title = (data.get("title") or "").strip()
        if (
            title
            and len(title) >= MIN_TITLE_LEN
            and not data.get("stickied")
            and not data.get("over_18")
        ):
            titles.append(title)

    return rng.choice(titles) if titles else None
