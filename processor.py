import subprocess
from transcriber import transcribe
from analyzer import analyze
from cutter import cut_video


def process_video(video_path: str, output_path: str) -> dict:
    """
    Full pipeline: transcribe → analyze → cut.
    Returns stats dict.
    """
    # Get original duration
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", video_path],
        capture_output=True, text=True,
    )
    original_duration = round(float(probe.stdout.strip()), 2)

    # Step 1: Transcribe
    segments = transcribe(video_path)

    # Step 2: Analyze with Gemini
    keep_ranges = analyze(segments, video_path)

    # Step 3: Cut
    result = cut_video(video_path, keep_ranges, output_path)

    # Get output duration
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", output_path],
        capture_output=True, text=True,
    )
    final_duration = round(float(probe.stdout.strip()), 2)

    removed_duration = round(original_duration - final_duration, 2)
    dead_space_pct = round((removed_duration / original_duration) * 100, 1) if original_duration > 0 else 0

    return {
        "original_duration": original_duration,
        "final_duration": final_duration,
        "removed_duration": removed_duration,
        "segments_kept": len(keep_ranges),
        "dead_space_percentage": dead_space_pct,
    }
