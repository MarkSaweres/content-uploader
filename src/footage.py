"""Fetches a royalty-free vertical background video clip from Pexels'
free API (https://www.pexels.com/api/ -- free account, no cost).
"""
from __future__ import annotations

import random

import requests

PEXELS_SEARCH_URL = "https://api.pexels.com/videos/search"


def _search(api_key: str, query: str, timeout: int = 20) -> list[dict]:
    resp = requests.get(
        PEXELS_SEARCH_URL,
        headers={"Authorization": api_key},
        params={"query": query, "orientation": "portrait", "size": "medium", "per_page": 15},
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json().get("videos", [])


def _best_file(video: dict) -> dict | None:
    files = [f for f in video.get("video_files", []) if f.get("width") and f.get("height")]
    portrait = [f for f in files if f["height"] > f["width"]]
    candidates = portrait or files
    if not candidates:
        return None
    return min(candidates, key=lambda f: abs((f["height"] or 0) - 1920))


def fetch_background_clip(
    api_key: str,
    keywords: list[str],
    out_path: str,
    min_duration_s: float,
    rng: random.Random | None = None,
    timeout: int = 60,
) -> str:
    rng = rng or random
    shuffled = list(keywords)
    rng.shuffle(shuffled)

    for query in shuffled:
        try:
            videos = _search(api_key, query)
        except requests.RequestException:
            continue
        candidates = [v for v in videos if v.get("duration", 0) >= min_duration_s]
        if not candidates:
            candidates = videos
        rng.shuffle(candidates)
        for video in candidates:
            file = _best_file(video)
            if not file:
                continue
            with requests.get(file["link"], stream=True, timeout=timeout) as r:
                r.raise_for_status()
                with open(out_path, "wb") as f:
                    for chunk in r.iter_content(chunk_size=1 << 20):
                        f.write(chunk)
            return out_path

    raise RuntimeError(f"No usable Pexels footage found for keywords: {keywords}")
