from pathlib import Path
import shutil
import uuid

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from learning.pitch import analyze_pitch
from learning.separation import get_vocal_stem


BASE_DIR = Path(__file__).resolve().parent

UPLOAD_DIR = BASE_DIR / "learning" / "uploads"
SEPARATED_DIR = BASE_DIR / "learning" / "separated"

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
SEPARATED_DIR.mkdir(parents=True, exist_ok=True)


app = FastAPI(title="Musiq Learning API")


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
def home():
    return {
        "message": "Musiq Learning API is running"
    }


@app.post("/analyze")
async def analyze_song(file: UploadFile = File(...)):

    allowed_extensions = {
        ".mp3",
        ".wav",
        ".m4a",
        ".ogg",
        ".flac",
    }

    extension = Path(file.filename or "").suffix.lower()

    if extension not in allowed_extensions:
        raise HTTPException(
            status_code=400,
            detail="Please upload an MP3, WAV, M4A, OGG, or FLAC audio file.",
        )

    job_id = uuid.uuid4().hex

    saved_path = UPLOAD_DIR / f"{job_id}{extension}"
    job_output_dir = SEPARATED_DIR / job_id

    try:
        # --------------------------------
        # 1. Save uploaded song
        # --------------------------------

        with saved_path.open("wb") as destination:
            shutil.copyfileobj(
                file.file,
                destination,
            )

        print(f"Learning upload: {saved_path}")

        # --------------------------------
        # 2. Separate vocals using Demucs
        # --------------------------------

        print("Starting Learning vocal separation...")

        vocal_path = get_vocal_stem(
            str(saved_path),
            str(job_output_dir),
        )

        print(f"Vocal stem created: {vocal_path}")

        # --------------------------------
        # 3. Analyze ONLY the vocal stem
        # --------------------------------

        print("Analyzing vocal pitch...")

        result = analyze_pitch(
            vocal_path
        )

        print("Learning analysis complete.")

        return {
            "job_id": job_id,
            "filename": file.filename,
            "vocal_file": str(
                Path(vocal_path).relative_to(
                    BASE_DIR
                )
            ),
            "duration": result["duration"],
            "sample_rate": result["sample_rate"],
            "pitch_curve": result["pitch_curve"],
        }

    except Exception as error:

        print(
            f"Learning analysis failed: {error}"
        )

        raise HTTPException(
            status_code=500,
            detail=f"Learning analysis failed: {error}",
        ) from error

    finally:
        await file.close()