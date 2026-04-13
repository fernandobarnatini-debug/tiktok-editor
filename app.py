import os
import uuid
from flask import Flask, request, jsonify, send_from_directory, render_template
from processor import process_video

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 300 * 1024 * 1024  # 300MB

UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "uploads")
PROCESSED_DIR = os.path.join(os.path.dirname(__file__), "processed")
ALLOWED_EXTENSIONS = {"mp4", "mov", "avi", "mkv", "webm"}

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(PROCESSED_DIR, exist_ok=True)


def allowed_file(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/upload", methods=["POST"])
def upload():
    if "video" not in request.files:
        return jsonify({"error": "No video file provided"}), 400

    file = request.files["video"]
    if file.filename == "":
        return jsonify({"error": "No file selected"}), 400

    if not allowed_file(file.filename):
        return jsonify({"error": f"Invalid format. Allowed: {', '.join(ALLOWED_EXTENSIONS)}"}), 400

    file_id = uuid.uuid4().hex[:8]
    ext = file.filename.rsplit(".", 1)[1].lower()
    input_filename = f"{file_id}_input.{ext}"
    output_filename = f"{file_id}_clean.mp4"

    input_path = os.path.join(UPLOAD_DIR, input_filename)
    output_path = os.path.join(PROCESSED_DIR, output_filename)

    file.save(input_path)

    try:
        stats = process_video(input_path, output_path)
        stats["download_url"] = f"/download/{output_filename}"
        stats["filename"] = file.filename
        return jsonify(stats)
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    finally:
        if os.path.exists(input_path):
            os.unlink(input_path)


@app.route("/download/<filename>")
def download(filename):
    return send_from_directory(PROCESSED_DIR, filename, as_attachment=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5050))
    app.run(host="0.0.0.0", port=port, debug=False)
