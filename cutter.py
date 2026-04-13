import os
import subprocess
import tempfile


def cut_video(video_path: str, keep_ranges: list[dict], output_path: str) -> dict:
    """
    Gemini says what to keep → FFmpeg cuts those ranges → concat with stream copy.
    No afade. No Whisper. No filler detection. Dead simple.
    """
    if not keep_ranges:
        raise ValueError("No keep ranges provided")

    tmpdir = tempfile.mkdtemp(prefix="tiktok_cut_")
    segment_files = []

    try:
        for i, r in enumerate(keep_ranges):
            seg_path = os.path.join(tmpdir, f"seg_{i:04d}.mp4")
            segment_files.append(seg_path)

            subprocess.run(
                [
                    "ffmpeg", "-y",
                    "-ss", str(r["start"]),
                    "-to", str(r["end"]),
                    "-i", video_path,
                    "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                    "-c:a", "aac", "-b:a", "128k",
                    seg_path,
                ],
                capture_output=True,
                check=True,
            )

        concat_list = os.path.join(tmpdir, "concat.txt")
        with open(concat_list, "w") as f:
            for seg_path in segment_files:
                f.write(f"file '{seg_path}'\n")

        subprocess.run(
            [
                "ffmpeg", "-y",
                "-f", "concat", "-safe", "0",
                "-i", concat_list,
                "-c", "copy",
                output_path,
            ],
            capture_output=True,
            check=True,
        )

        return {"keep_ranges": keep_ranges}

    finally:
        for seg_path in segment_files:
            if os.path.exists(seg_path):
                os.unlink(seg_path)
        if os.path.exists(concat_list):
            os.unlink(concat_list)
        if os.path.exists(tmpdir):
            os.rmdir(tmpdir)


if __name__ == "__main__":
    import sys
    import json
    from transcriber import transcribe
    from analyzer import analyze

    video = sys.argv[1] if len(sys.argv) > 1 else "/Users/isaacsahyoun/Desktop/IMG_3499.MOV"
    output = os.path.join(os.path.dirname(video), "IMG_3499_clean.mp4")

    print("=== Transcribing ===")
    segments = transcribe(video)
    for seg in segments:
        print(f"  [{seg['start']:6.2f} → {seg['end']:6.2f}]  {seg['text']}")

    print(f"\n=== Building keep ranges ===")
    keep_ranges = analyze(segments, video)
    print(f"  Keep ranges: {len(keep_ranges)}")
    for r in keep_ranges:
        dur = r["end"] - r["start"]
        print(f"  [{r['start']:6.2f} → {r['end']:6.2f}]  ({dur:.2f}s)")

    print(f"\n=== Cutting video ===")
    result = cut_video(video, keep_ranges, output)

    # Verify
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", output],
        capture_output=True, text=True,
    )
    out_dur = float(probe.stdout.strip())

    probe_orig = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", video],
        capture_output=True, text=True,
    )
    orig_dur = float(probe_orig.stdout.strip())

    audio_check = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a",
         "-show_entries", "stream=codec_name",
         "-of", "default=noprint_wrappers=1:nokey=1", output],
        capture_output=True, text=True,
    )
    has_audio = bool(audio_check.stdout.strip())

    print(f"\n=== Done ===")
    print(f"  Original:  {orig_dur:.2f}s")
    print(f"  Output:    {out_dur:.2f}s")
    print(f"  Removed:   {orig_dur - out_dur:.2f}s ({(orig_dur - out_dur) / orig_dur * 100:.1f}%)")
    print(f"  Has audio: {'YES' if has_audio else 'NO — PROBLEM!'}")
    print(f"  Output at: {output}")
