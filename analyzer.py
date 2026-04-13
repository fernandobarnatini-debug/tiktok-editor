import json
import os
import subprocess
import tempfile
import requests
import torch

# Load VAD model once
torch.hub._validate_not_a_forked_repo = lambda a, b, c: True
_vad_model, _vad_utils = torch.hub.load("snakers4/silero-vad", "silero_vad", trust_repo=True)
_get_speech_timestamps, _, _read_audio, _, _ = _vad_utils

SAMPLING_RATE = 16000
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = "google/gemini-2.0-flash-001"

RETAKE_PROMPT = """You are a video editor AI. You receive a list of speech segments from a TikTok video, each with its transcript text and time range.

Your job: detect RETAKES. When a speaker starts the same sentence or similar phrasing multiple times, those are retakes — false starts, mess-ups, do-overs. Keep ONLY the last complete version of each repeated sentence. Cut all previous attempts.

Rules:
- If you see 2+ segments that start with the same or very similar words, those are retakes of the same sentence.
- The LAST attempt is almost always the best and most complete one. Keep it, cut the earlier ones.
- Segments that are NOT retakes should all be kept — do not cut unique content.
- An incomplete sentence that trails off and is followed by a similar sentence starting the same way = retake. Cut the incomplete one.

Return the INDICES (0-based) of the segments to KEEP. Return valid JSON only — no markdown, no explanation. Just a JSON array of integers.

Example: if there are 8 segments and segments 3 and 4 are retakes of the same sentence (keep 4, cut 3), return:
[0, 1, 2, 4, 5, 6, 7]"""


def _get_api_key() -> str:
    api_key = os.environ.get("OPENROUTER_API_KEY", "")
    if not api_key:
        env_path = os.path.join(os.path.dirname(__file__), ".env")
        if os.path.exists(env_path):
            with open(env_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("OPENROUTER_API_KEY="):
                        api_key = line.split("=", 1)[1].strip()
                        break
    return api_key


def _get_vad_ranges(video_path: str) -> list[dict]:
    """Detect speech using Silero VAD. Returns keep ranges."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_audio = tmp.name

    try:
        subprocess.run(
            [
                "ffmpeg", "-y", "-i", video_path,
                "-vn", "-acodec", "pcm_s16le",
                "-ar", str(SAMPLING_RATE), "-ac", "1",
                tmp_audio,
            ],
            capture_output=True, check=True,
        )

        wav = _read_audio(tmp_audio)
        timestamps = _get_speech_timestamps(wav, _vad_model, sampling_rate=SAMPLING_RATE)

        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", video_path],
            capture_output=True, text=True,
        )
        total_duration = float(probe.stdout.strip())

        keep_ranges = []
        for t in timestamps:
            start = max(0, t["start"] / SAMPLING_RATE - 0.05)
            end = min(total_duration, t["end"] / SAMPLING_RATE + 0.05)
            keep_ranges.append({"start": round(start, 2), "end": round(end, 2)})

        # Merge segments that are very close (< 0.15s gap)
        if not keep_ranges:
            return []

        merged = [keep_ranges[0].copy()]
        for r in keep_ranges[1:]:
            if r["start"] - merged[-1]["end"] <= 0.15:
                merged[-1]["end"] = r["end"]
            else:
                merged.append(r.copy())

        return merged

    finally:
        if os.path.exists(tmp_audio):
            os.unlink(tmp_audio)


def _label_ranges_with_text(vad_ranges: list[dict], segments: list[dict]) -> list[dict]:
    """Map transcript text onto VAD ranges using word-level timestamps."""
    # Flatten all words from all segments
    all_words = []
    for seg in segments:
        for w in seg.get("words", []):
            all_words.append(w)

    labeled = []
    for r in vad_ranges:
        # Find words whose timestamps overlap with this VAD range
        words_in_range = [
            w["word"] for w in all_words
            if w["start"] < r["end"] and w["end"] > r["start"]
        ]
        text = " ".join(words_in_range).strip() if words_in_range else "[no transcript]"
        labeled.append({
            "start": r["start"],
            "end": r["end"],
            "text": text,
        })
    return labeled


def _detect_retakes(labeled_ranges: list[dict]) -> list[dict]:
    """Send labeled ranges to Gemini to detect retakes. Returns filtered ranges."""
    api_key = _get_api_key()
    if not api_key:
        # No API key — skip retake detection, return all ranges
        return [{"start": r["start"], "end": r["end"]} for r in labeled_ranges]

    # Build user message
    segments_text = ""
    for i, r in enumerate(labeled_ranges):
        segments_text += f'[{i}] [{r["start"]:.2f} → {r["end"]:.2f}] "{r["text"]}"\n'

    user_msg = f"""Here are {len(labeled_ranges)} speech segments from a TikTok video:

{segments_text}
Which segment indices should be KEPT? Return a JSON array of indices."""

    try:
        response = requests.post(
            OPENROUTER_URL,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": MODEL,
                "messages": [
                    {"role": "system", "content": RETAKE_PROMPT},
                    {"role": "user", "content": user_msg},
                ],
                "temperature": 0.1,
            },
            timeout=30,
        )
        response.raise_for_status()

        raw = response.json()["choices"][0]["message"]["content"].strip()

        # Strip markdown code fences
        if raw.startswith("```"):
            raw = raw.split("\n", 1)[1] if "\n" in raw else raw[3:]
            if raw.endswith("```"):
                raw = raw[:-3]
            raw = raw.strip()

        keep_indices = json.loads(raw)

        # Filter to only kept indices
        filtered = []
        for i in keep_indices:
            if 0 <= i < len(labeled_ranges):
                r = labeled_ranges[i]
                filtered.append({"start": r["start"], "end": r["end"]})

        return filtered

    except Exception:
        # If Gemini fails, return all ranges (safe fallback)
        return [{"start": r["start"], "end": r["end"]} for r in labeled_ranges]


def analyze(segments: list[dict], video_path: str) -> list[dict]:
    """
    1. VAD detects speech ranges
    2. Map transcript text onto VAD ranges
    3. Gemini detects retakes → keeps only last take
    """
    # Step 1: VAD
    vad_ranges = _get_vad_ranges(video_path)

    # Step 2: Label with transcript
    labeled = _label_ranges_with_text(vad_ranges, segments)

    # Step 3: Retake detection
    filtered = _detect_retakes(labeled)

    return filtered


if __name__ == "__main__":
    import sys
    from transcriber import transcribe

    path = sys.argv[1] if len(sys.argv) > 1 else "/Users/isaacsahyoun/Desktop/IMG_3499.MOV"

    print(f"=== Transcribing: {path} ===\n")
    segments = transcribe(path)
    for seg in segments:
        print(f"  [{seg['start']:6.2f} → {seg['end']:6.2f}]  {seg['text']}")

    print(f"\n=== VAD Speech Detection ===\n")
    vad_ranges = _get_vad_ranges(path)
    for r in vad_ranges:
        dur = r["end"] - r["start"]
        print(f"  [{r['start']:6.2f} → {r['end']:6.2f}]  ({dur:.2f}s)")

    print(f"\n=== Labeled ranges ===\n")
    labeled = _label_ranges_with_text(vad_ranges, segments)
    for i, r in enumerate(labeled):
        print(f"  [{i}] [{r['start']:6.2f} → {r['end']:6.2f}]  \"{r['text']}\"")

    print(f"\n=== Retake detection (Gemini) ===\n")
    keep_ranges = analyze(segments, path)

    total_kept = 0
    for r in keep_ranges:
        dur = r["end"] - r["start"]
        total_kept += dur
        print(f"  [{r['start']:6.2f} → {r['end']:6.2f}]  ({dur:.2f}s)")

    print(f"\nKeep ranges: {len(keep_ranges)}")
    print(f"Total speech: {total_kept:.2f}s")
