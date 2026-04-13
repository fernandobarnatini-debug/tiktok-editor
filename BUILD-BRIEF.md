# TikTok Dead Space Remover — V1 Build Brief

## What This App Does
Upload a TikTok Shop video → AI analyzes the transcript → decides what's dead space → FFmpeg cuts it out → download a clean, ready-to-post video. One click.

## How It Works (The Flow)
```
User uploads video
    ↓
FFmpeg extracts audio
    ↓
Whisper transcribes audio → full transcript with sentence timestamps
    ↓
Gemini 2.0 Flash analyzes transcript → decides what to keep vs cut
    ↓
Gemini returns a JSON cut list: [{keep: 0.0-2.1}, {cut: 2.1-3.9}, {keep: 3.9-6.2}, ...]
    ↓
FFmpeg cuts the video at those exact points
    ↓
FFmpeg concatenates the "keep" segments
    ↓
User downloads the clean video
```

## Tech Stack
| Layer | Tool | Role |
|-------|------|------|
| Transcription | Whisper (base.en, local) | Speech → text with segment timestamps |
| Brain | Gemini 2.0 Flash (via OpenRouter) | Analyzes transcript, decides what to cut |
| Video processing | FFmpeg (local) | Extracts audio, cuts video, concatenates |
| Backend | Python + Flask | Web server, orchestrates the pipeline |
| Frontend | HTML/CSS/JS | Upload UI, settings, download |

## Step-by-Step Build Order

### Step 1: Project Setup
- Create project directory at ~/Projects/tiktok-editor/
- Create Python venv
- Install dependencies: flask, pydub, audioop-lts, requests
- Create folder structure: app.py, processor.py, templates/, uploads/, processed/
- Verify FFmpeg and Whisper are accessible

### Step 2: Build the Whisper Transcription Module
- File: `transcriber.py`
- Function: takes a video file path → extracts audio with FFmpeg → runs Whisper → returns transcript with SEGMENT-level timestamps
- Output format: list of segments, each with {text, start, end}
- Use Whisper's segment timestamps ONLY — not word-level (word timestamps are inaccurate)
- Test: run on /Users/isaacsahyoun/Desktop/IMG_3499.MOV, print all segments with timestamps

### Step 3: Build the AI Analysis Module
- File: `analyzer.py`
- Function: takes the transcript segments → sends to Gemini 2.0 Flash via OpenRouter → gets back a cut list
- The prompt to Gemini:
  - "Here's a transcript of a TikTok video with timestamps. Identify all dead space — silence, pauses, filler (um, uh, like, you know), and any gaps where nothing meaningful is being said. Return a JSON list of segments to KEEP. Each segment has a start and end time in seconds. Only keep segments with actual meaningful speech. Remove all dead air, filler words, and unnecessary pauses. Make the cuts at natural sentence boundaries so it sounds seamless."
- Gemini returns: [{"start": 0.0, "end": 2.1}, {"start": 3.9, "end": 6.2}, ...]
- Parse the JSON response
- Test: run on the transcript from Step 2, print the cut list

### Step 4: Build the FFmpeg Cutting Module
- File: `cutter.py`
- Function: takes the original video + the cut list from Gemini → cuts each "keep" segment → concatenates into final video
- Use: ffmpeg -ss START -to END for each segment
- Use: ffmpeg -f concat for joining
- Encoding: -c:v libx264 -preset fast -crf 18 -c:a aac -b:a 128k
- DO NOT use audio fade filters (afade) — they break the audio
- Test: run on IMG_3499.MOV with the cut list from Step 3, verify output has audio and plays correctly

### Step 5: Build the Processor Pipeline
- File: `processor.py`
- Function: orchestrates the full pipeline — transcribe → analyze → cut
- Takes: video_path, output_path
- Returns: stats dict {original_duration, final_duration, removed_duration, segments_kept, dead_space_percentage}
- This is the main function the Flask app calls

### Step 6: Build the Flask App
- File: `app.py`
- Routes: GET / (upload page), POST /upload (process video), GET /download/<file> (download result)
- Max upload: 100MB
- Allowed formats: mp4, mov, avi, mkv, webm
- Saves uploaded file, runs processor, returns stats + download link as JSON

### Step 7: Build the Frontend
- File: `templates/index.html`
- Dark theme (TikTok aesthetic — black bg, red #fe2c55 accent, cyan #25f4ee accent)
- Drag & drop upload area
- "Remove Dead Space" button
- Loading spinner during processing
- Results: stats cards (original duration, final duration, % removed, cuts made)
- Download button
- Clean, mobile-friendly

### Step 8: Test End-to-End
- Start Flask server on localhost:5050
- Upload /Users/isaacsahyoun/Desktop/IMG_3499.MOV
- Verify: transcript is generated, Gemini returns cut list, FFmpeg produces video
- Verify: output video has audio, sounds natural, dead space is removed
- Verify: stats are accurate

## Critical Rules
- DO NOT use Whisper word-level timestamps — use segment-level only
- DO NOT use audio fade filters (afade) — they destroy the audio
- DO NOT use pydub for the actual cutting — use FFmpeg directly
- DO NOT overcomplicate — transcribe → AI analyze → cut. Three steps.
- The AI (Gemini) is the brain. It decides what to cut. FFmpeg is the muscle. It executes.

## API Setup
- OpenRouter API: https://openrouter.ai/api/v1/chat/completions
- Model: google/gemini-2.0-flash-001
- API key: will be provided as environment variable OPENROUTER_API_KEY
- Keep the Gemini prompt focused: give it timestamps + text, ask for keep-segments back as JSON

## Test Video
/Users/isaacsahyoun/Desktop/IMG_3499.MOV — 27 seconds, talking head with lots of pauses and dead air.
Target: should cut down to ~10-12 seconds of clean speech.

## Definition of Done
Upload the test video → AI analyzes → cuts are made → download the result. The output should:
- Remove all obvious dead air and pauses
- Keep all meaningful spoken words intact
- Have working audio (not silent)
- Sound natural at the cut points
- Cut at sentence boundaries, not mid-word
