#!/usr/bin/env python3
"""End-to-end pipeline: generate an original short story, narrate it,
fetch background footage, burn in captions, assemble the video, and
(optionally) upload it to YouTube Shorts.

Usage:
    python main.py                 # full run, uploads to YouTube
    python main.py --dry-run       # builds the video but skips upload
    python main.py --theme aita    # force a specific theme from config.yaml
"""
from __future__ import annotations

import argparse
import math
import os
import random
import shutil
import sys
import time

import yaml
from dotenv import load_dotenv

from src import captions, footage, story_generator, tts, video_builder, youtube_uploader

ROOT = os.path.dirname(os.path.abspath(__file__))


def load_config() -> dict:
    with open(os.path.join(ROOT, "config.yaml"), "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def build_youtube_metadata(cfg: dict, story) -> dict:
    hashtags = " ".join(cfg["youtube"]["hashtags"])
    first_line = story.text.strip().splitlines()[0]
    hook = (first_line[:70] + "...") if len(first_line) > 70 else first_line
    title = f"{hook} {hashtags}".strip()
    description = f"{story.text}\n\n{hashtags}"
    tags = [story.theme_id, "reddit", "storytime", "shorts"]
    return {"title": title, "description": description, "tags": tags}


def run(args: argparse.Namespace) -> str:
    load_dotenv(os.path.join(ROOT, ".env"))
    cfg = load_config()
    rng = random.Random()

    theme = next((t for t in cfg["themes"] if t["id"] == args.theme), None) if args.theme else None
    theme = theme or story_generator.pick_theme(cfg["themes"], rng)
    print(f"[1/5] Theme: {theme['label']}")

    groq_key = os.environ.get("GROQ_API_KEY")
    if not groq_key:
        sys.exit("GROQ_API_KEY is not set (see .env.example).")
    story = story_generator.generate_story(groq_key, theme)
    print(f"      Story ({len(story.text.split())} words): {story.text[:80]}...")

    run_id = time.strftime("%Y%m%d-%H%M%S")
    work_dir = os.path.join(ROOT, "output", run_id)
    os.makedirs(work_dir, exist_ok=True)

    print("[2/5] Generating narration...")
    narration_path = os.path.join(work_dir, "narration.mp3")
    narration = tts.generate_narration(
        story.text, cfg["tts"]["voice"], cfg["tts"]["rate"], narration_path
    )
    if not narration.words or narration.duration_s <= 0:
        sys.exit("TTS produced no word timings -- narration/captions would be broken. Aborting.")
    print(f"      Duration: {narration.duration_s:.1f}s")

    print("[3/5] Building captions...")
    ass_path = os.path.join(work_dir, "captions.ass")
    captions.build_ass(
        narration.words,
        ass_path,
        width=cfg["video"]["width"],
        height=cfg["video"]["height"],
        font=cfg["video"]["font"],
        font_size=cfg["video"]["font_size"],
        words_per_group=cfg["video"]["caption_words_per_group"],
    )

    print("[4/5] Fetching background footage + assembling video...")
    pexels_key = os.environ.get("PEXELS_API_KEY")
    if not pexels_key:
        sys.exit("PEXELS_API_KEY is not set (see .env.example).")
    num_clips = max(1, math.ceil(narration.duration_s / cfg["video"]["clip_segment_s"]))
    background_paths = footage.fetch_background_clips(
        pexels_key, story.search_keywords, work_dir, count=num_clips, rng=rng
    )
    print(f"      Using {len(background_paths)} background clip(s)")

    final_path = os.path.join(ROOT, "output", f"{run_id}_{story.theme_id}.mp4")
    video_builder.build_short(
        background_paths,
        narration_path,
        ass_path,
        final_path,
        duration_s=narration.duration_s,
        width=cfg["video"]["width"],
        height=cfg["video"]["height"],
        fps=cfg["video"]["fps"],
    )
    print(f"      Wrote {final_path}")

    if not args.keep_temp:
        shutil.rmtree(work_dir, ignore_errors=True)

    if args.dry_run:
        print("[5/5] --dry-run set: skipping YouTube upload.")
        return final_path

    print("[5/5] Uploading to YouTube Shorts...")
    meta = build_youtube_metadata(cfg, story)
    youtube = youtube_uploader.authenticate(
        os.environ["YOUTUBE_CLIENT_SECRET_FILE"], os.environ["YOUTUBE_TOKEN_FILE"]
    )
    video_id = youtube_uploader.upload_short(
        youtube,
        final_path,
        title=meta["title"],
        description=meta["description"],
        tags=meta["tags"],
        category_id=cfg["youtube"]["category_id"],
        privacy_status=cfg["youtube"]["privacy_status"],
        made_for_kids=cfg["youtube"]["made_for_kids"],
    )
    print(f"      Uploaded: https://youtube.com/shorts/{video_id}")
    return final_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Build the video but don't upload it")
    parser.add_argument("--keep-temp", action="store_true", help="Keep intermediate files (narration, background, captions)")
    parser.add_argument("--theme", help="Force a specific theme id from config.yaml instead of a random one")
    return parser.parse_args()


if __name__ == "__main__":
    run(parse_args())
