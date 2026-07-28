# Content Uploader

Generates an original short "Reddit story" style video (AI voiceover +
stock background footage + burned-in captions) and uploads it to YouTube
Shorts, on a schedule, using only free-tier services.

## Pipeline

```
theme (config.yaml) --> story_generator.py (Groq LLM, free)
                     --> tts.py            (edge-tts narration + word timings, free)
                     --> captions.py       (word timings -> .ass captions)
                     --> footage.py        (Pexels stock video, free)
                     --> video_builder.py  (ffmpeg: crop/loop bg + burn captions + mux audio)
                     --> youtube_uploader.py (YouTube Data API v3 upload)
```

Every run picks a random theme from `config.yaml` (AITA, TIFU, confession,
relationship advice, short horror) and generates a brand-new story rather
than reusing/scraping real Reddit posts — this keeps content original and
avoids the "reused/duplicative content" monetization penalty platforms
apply to copy-paste channels.

## 1. Local setup

```bash
git clone https://github.com/MarkSaweres/content-uploader.git && cd content-uploader
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
sudo apt-get install -y ffmpeg   # or brew install ffmpeg on macOS
cp .env.example .env
```

### Free API keys

- **Groq** (story generation): sign up at https://console.groq.com/keys,
  create an API key, put it in `.env` as `GROQ_API_KEY`. Free tier is
  generous for this use case (one short request per video).
- **Pexels** (background footage): sign up at https://www.pexels.com/api/,
  put the key in `.env` as `PEXELS_API_KEY`.

### YouTube upload (Google Cloud + OAuth)

1. Create a project at https://console.cloud.google.com.
2. Enable the **YouTube Data API v3** (APIs & Services > Library).
3. Configure the **OAuth consent screen** (External is fine; add your own
   Google account as a test user — no Google review needed while it's in
   "Testing" mode, which allows up to 100 test users and is enough for a
   single-channel bot).
4. Create an **OAuth client ID** of type **Desktop app**, download the
   JSON, save it as `youtube_client_secret.json` in this repo's root.
5. Run once locally to complete the browser consent flow (this opens a
   browser — it cannot be done headlessly in CI):
   ```bash
   python -c "from src.youtube_uploader import authenticate; authenticate('youtube_client_secret.json', 'youtube_token.json')"
   ```
   This creates `youtube_token.json`, which holds a refresh token main.py
   and the GitHub Actions workflow reuse for all future runs.

### Run it

```bash
python main.py --dry-run          # builds output/*.mp4, skips upload — inspect it first!
python main.py --theme aita       # force a theme instead of random
python main.py                    # full run including YouTube upload
```

## 2. Running on a schedule for free (GitHub Actions)

`.github/workflows/content-pipeline.yml` runs the pipeline once a day (cron)
and can also be triggered manually from the Actions tab. It needs these
**repository secrets** (Settings > Secrets and variables > Actions):

| Secret | Value |
|---|---|
| `GROQ_API_KEY` | your Groq key |
| `PEXELS_API_KEY` | your Pexels key |
| `YOUTUBE_CLIENT_SECRET_JSON` | `base64 -w0 youtube_client_secret.json` |
| `YOUTUBE_TOKEN_JSON` | `base64 -w0 youtube_token.json` (generated in step 5 above) |

The refresh token in `youtube_token.json` doesn't expire from use, so you
only need to regenerate/re-encode it if you revoke access or change scopes.

**YouTube API quota**: the default project quota is 10,000 units/day and
an upload costs ~1,600 units, so you can upload roughly **6 videos/day**
before hitting the cap (request a quota increase from Google if you need
more — it's free but requires an audit form).

## 3. Before you turn this fully loose, read this

- **Monetization policy risk**: YouTube's Partner Program, TikTok's Creator
  Rewards Program, and Facebook's monetization terms all explicitly exclude
  "repetitious," "mass-produced," or "duplicative" content. This pipeline
  reduces that risk (original stories, rotated themes/voices/footage per
  run) but doesn't eliminate it — a channel that's obviously templated
  output on autopilot is still a plausible target for a policy review.
  Treat this as a strong starting point, not a guarantee.
- **Content review**: the LLM system prompt restricts explicit/harmful
  content, but isn't foolproof. Especially for the first few weeks, use
  `--dry-run` and skim each video before flipping on unattended auto-upload.
- **Eligibility thresholds still apply**: YouTube Shorts monetization
  currently requires 1,000 subscribers and either 10M valid public Shorts
  views in 90 days or 4,000 watch hours in 12 months — automation gets you
  volume, not an exemption from these thresholds.
- **TikTok / Instagram / Facebook**: not wired up yet. TikTok's Content
  Posting API and Meta's Graph API both require an app review/audit before
  they'll let an app post publicly on your behalf (unaudited apps can only
  post as private/draft) — that's a process only you can complete as the
  account/app owner. Once you have an approved app + access token, adding
  a `tiktok_uploader.py` / `facebook_uploader.py` alongside
  `youtube_uploader.py` and calling it from `main.py` is straightforward.

## File overview

- `config.yaml` — themes/prompts, TTS voice, video/caption styling, YouTube metadata defaults.
- `src/story_generator.py` — Groq chat completion call, one theme -> one original story.
- `src/tts.py` — edge-tts narration + per-word timing capture.
- `src/captions.py` — word timings -> styled `.ass` subtitle file.
- `src/footage.py` — Pexels portrait video search + download.
- `src/video_builder.py` — ffmpeg crop/loop/caption-burn/mux into the final vertical mp4.
- `src/youtube_uploader.py` — OAuth + resumable upload via YouTube Data API v3.
- `main.py` — orchestrates the pipeline; `--dry-run` / `--theme` / `--keep-temp` flags.
