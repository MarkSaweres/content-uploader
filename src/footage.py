"""Fetches royalty-free vertical background video clips from Pexels'
free API (https://www.pexels.com/api/ -- free account, no cost).
"""
from __future__ import annotations

import os
import random

import requests

PEXELS_SEARCH_URL = "https://api.pexels.com/videos/search"


def _search(api_key: str, query: str, page: int = 1, timeout: int = 20) -> list[dict]:
    resp = requests.get(
        PEXELS_SEARCH_URL,
        headers={"Authorization": api_key},
        params={
            "query": query,
            "orientation": "portrait",
            "size": "medium",
            "per_page": 15,
            "page": page,
        },
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


def _download(url: str, out_path: str, timeout: int) -> None:
    with requests.get(url, stream=True, timeout=timeout) as r:
        r.raise_for_status()
        with open(out_path, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)


def fetch_background_clips(
    api_key: str,
    keywords: list[str],
    out_dir: str,
    count: int,
    rng: random.Random | None = None,
    timeout: int = 60,
) -> list[str]:
    """Downloads `count` distinct background clips, cycling through the
    theme's keywords (with randomized result pages) so a longer video cuts
    between several different clips instead of looping one the whole way
    through.
    """
    rng = rng or random
    queries = list(keywords)
    rng.shuffle(queries)

    used_ids: set = set()
    paths: list[str] = []
    max_attempts = count * 8
    attempt = 0

    while len(paths) < count and attempt < max_attempts:
        query = queries[attempt % len(queries)]
        page = rng.randint(1, 5)
        attempt += 1
        try:
            videos = _search(api_key, query, page=page)
        except requests.RequestException:
            continue
        rng.shuffle(videos)
        for video in videos:
            if video["id"] in used_ids:
                continue
            file = _best_file(video)
            if not file:
                continue
            out_path = os.path.join(out_dir, f"bg_{len(paths)}.mp4")
            try:
                _download(file["link"], out_path, timeout)
            except requests.RequestException:
                continue
            used_ids.add(video["id"])
            paths.append(out_path)
            break

    if not paths:
        raise RuntimeError(f"No usable Pexels footage found for keywords: {keywords}")

    # Reuse already-downloaded clips (round-robin) if Pexels ran dry before
    # we hit `count` -- still better than erroring out over a variety shortfall.
    while len(paths) < count:
        paths.append(paths[len(paths) % len(paths)])

    return paths
