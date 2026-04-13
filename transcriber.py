import subprocess
import tempfile
import os
import whisper


def transcribe(video_path: str) -> list[dict]:
    """
    Takes a video file path, extracts audio with FFmpeg,
    runs Whisper (base.en), and returns segment-level timestamps.

    Returns: list of {"text": str, "start": float, "end": float}
    """
    # Extract audio to a temp WAV file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_audio = tmp.name

    try:
        subprocess.run(
            [
                "ffmpeg", "-y",
                "-i", video_path,
                "-vn",                # no video
                "-acodec", "pcm_s16le",
                "-ar", "16000",       # 16kHz mono — what Whisper expects
                "-ac", "1",
                tmp_audio,
            ],
            capture_output=True,
            check=True,
        )

        model = whisper.load_model("base.en")
        result = model.transcribe(tmp_audio, language="en", word_timestamps=True)

        segments = []
        for seg in result["segments"]:
            words = [
                {
                    "word": w["word"].strip(),
                    "start": round(w["start"], 2),
                    "end": round(w["end"], 2),
                }
                for w in seg.get("words", [])
            ]
            segments.append({
                "text": seg["text"].strip(),
                "start": round(seg["start"], 2),
                "end": round(seg["end"], 2),
                "words": words,
            })

        return segments

    finally:
        if os.path.exists(tmp_audio):
            os.unlink(tmp_audio)


if __name__ == "__main__":
    import sys
    import json

    path = sys.argv[1] if len(sys.argv) > 1 else "/Users/isaacsahyoun/Desktop/IMG_3499.MOV"
    print(f"Transcribing: {path}\n")

    segments = transcribe(path)

    for seg in segments:
        print(f"[{seg['start']:6.2f} → {seg['end']:6.2f}]  {seg['text']}")

    print(f"\nTotal segments: {len(segments)}")
    print(f"\nRaw JSON:\n{json.dumps(segments, indent=2)}")
