from pathlib import Path
import shutil
import uuid

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from learning.pitch import analyze_pitch


BASE_DIR = Path(__file__).resolve().parent

UPLOAD_DIR = BASE_DIR / "learning" / "uploads"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)


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
        "message": "Musiq Learning API is running",
        "endpoint": "/analyze",
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
    output_path = UPLOAD_DIR / f"{job_id}.analysis.json"

    try:
        with saved_path.open("wb") as destination:
            shutil.copyfileobj(file.file, destination)

        result = analyze_pitch(
            str(saved_path),
            str(output_path),
        )

        return {
            "job_id": job_id,
            "filename": file.filename,
            "duration": result["duration"],
            "sample_rate": result["sample_rate"],
            "pitch_curve": result["pitch_curve"],
        }

    except Exception as error:
        raise HTTPException(
            status_code=500,
            detail=f"Audio analysis failed: {error}",
        ) from error

    finally:
        await file.close()