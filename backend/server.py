from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

import shutil
import subprocess
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf
import librosa


app = FastAPI(title="Musiq Backend")


# ---------------------------------------------------------
# CORS
# ---------------------------------------------------------

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------
# DIRECTORIES
# ---------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent

UPLOAD_DIR = BASE_DIR / "uploads"
OUTPUT_DIR = BASE_DIR / "server_output"

UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)


# Serve generated audio files
app.mount(
    "/audio",
    StaticFiles(directory=str(OUTPUT_DIR)),
    name="audio",
)


# ---------------------------------------------------------
# ROOT
# ---------------------------------------------------------

@app.get("/")
def root():
    return {
        "app": "Musiq",
        "status": "running",
    }


# ---------------------------------------------------------
# SEPARATE SONG
# ---------------------------------------------------------

@app.post("/separate")
async def separate_song(file: UploadFile = File(...)):

    if not file.filename:
        raise HTTPException(
            status_code=400,
            detail="No file selected",
        )

    job_id = str(uuid.uuid4())[:8]

    extension = Path(file.filename).suffix.lower()

    if extension not in [
        ".mp3",
        ".wav",
        ".m4a",
        ".flac",
        ".ogg",
    ]:
        raise HTTPException(
            status_code=400,
            detail="Unsupported audio format",
        )

    job_dir = OUTPUT_DIR / job_id
    job_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    input_file = UPLOAD_DIR / f"{job_id}{extension}"

    # Save uploaded song
    with open(input_file, "wb") as buffer:
        shutil.copyfileobj(
            file.file,
            buffer,
        )

    print()
    print("=" * 60)
    print("MUSIQ")
    print("New song received")
    print(f"File: {file.filename}")
    print(f"Job ID: {job_id}")
    print("=" * 60)
    print()

    # -----------------------------------------------------
    # RUN DEMUCS
    # -----------------------------------------------------

    try:

        command = [
            "python3",
            "-m",
            "demucs",
            "-o",
            str(job_dir),
            str(input_file),
        ]

        print("Running Demucs...")
        print(" ".join(command))
        print()

        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
        )

        print(result.stdout)

        if result.returncode != 0:
            print(result.stderr)

            raise HTTPException(
                status_code=500,
                detail="Demucs separation failed",
            )

    except HTTPException:
        raise

    except Exception as e:

        print("ERROR:", e)

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )

    # -----------------------------------------------------
    # FIND GENERATED WAV FILES
    # -----------------------------------------------------

    possible_files = list(
        job_dir.rglob("*.wav")
    )

    if not possible_files:

        raise HTTPException(
            status_code=500,
            detail="No separated audio files were created",
        )

    print()
    print("Separated files:")

    for path in possible_files:
        print(path)

    # -----------------------------------------------------
    # FIND FOUR STEMS
    # -----------------------------------------------------

    stems = {}

    for stem_name in [
        "vocals",
        "drums",
        "bass",
        "other",
    ]:

        matches = [
            path
            for path in job_dir.rglob(
                f"{stem_name}.wav"
            )
            if "transpose_" not in path.parts
        ]

        if matches:

            relative_path = (
                matches[0]
                .relative_to(job_dir)
                .as_posix()
            )

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"{relative_path}"
            )

    if len(stems) < 4:

        raise HTTPException(
            status_code=500,
            detail={
                "message": "Not all four stems were found",
                "found": list(stems.keys()),
            },
        )

    print()
    print("Musiq separation complete!")
    print(f"Job ID: {job_id}")
    print()

    return {
        "success": True,
        "job_id": job_id,
        "filename": file.filename,
        "stems": stems,
    }


# ---------------------------------------------------------
# TRANSPOSE STEMS
# ---------------------------------------------------------

@app.post("/transpose")
async def transpose_stems(data: dict):

    job_id = data.get("job_id")

    if not job_id:

        raise HTTPException(
            status_code=400,
            detail="Missing job_id",
        )

    # Convert transpose value to float
    try:
        semitones = float(
            data.get("semitones", 0)
        )

    except (TypeError, ValueError):

        raise HTTPException(
            status_code=400,
            detail="Invalid transpose value",
        )

    # -----------------------------------------------------
    # LIMIT
    # -----------------------------------------------------

    if semitones < -12 or semitones > 12:

        raise HTTPException(
            status_code=400,
            detail="Transpose must be between -12 and +12 semitones",
        )

    job_dir = OUTPUT_DIR / job_id

    if not job_dir.exists():

        raise HTTPException(
            status_code=404,
            detail="Song session not found",
        )

    # -----------------------------------------------------
    # 0 SEMITONES
    # -----------------------------------------------------

    if semitones == 0:

        stems = {}

        for stem_name in [
            "vocals",
            "drums",
            "bass",
            "other",
        ]:

            matches = [
                path
                for path in job_dir.rglob(
                    f"{stem_name}.wav"
                )
                if "transpose_" not in path.parts
            ]

            if matches:

                relative_path = (
                    matches[0]
                    .relative_to(job_dir)
                    .as_posix()
                )

                stems[stem_name] = (
                    f"/audio/{job_id}/"
                    f"{relative_path}"
                )

        return {
            "success": True,
            "job_id": job_id,
            "semitones": 0,
            "stems": stems,
        }

    # -----------------------------------------------------
    # CREATE TRANSPOSE FOLDER
    # -----------------------------------------------------

    shift_name = str(int(semitones))

    transpose_dir = (
        job_dir / f"transpose_{shift_name}"
    )

    transpose_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    print()
    print("=" * 60)
    print("MUSIQ TRANSPOSE")
    print(f"Job ID: {job_id}")
    print(f"Transpose: {semitones:+g} semitones")
    print("=" * 60)
    print()

    # -----------------------------------------------------
    # PROCESS EACH STEM
    # -----------------------------------------------------

    stem_names = [
        "vocals",
        "drums",
        "bass",
        "other",
    ]

    try:

        for stem_name in stem_names:

            # Find ORIGINAL stem only
            matches = [
                path
                for path in job_dir.rglob(
                    f"{stem_name}.wav"
                )
                if "transpose_" not in path.parts
            ]

            if not matches:

                print(
                    f"Skipping {stem_name}: "
                    "original stem not found"
                )

                continue

            source_file = matches[0]

            output_file = (
                transpose_dir /
                f"{stem_name}.wav"
            )

            # If this transpose version already exists,
            # don't calculate it again.
            if output_file.exists():

                print(
                    f"{stem_name}: already exists"
                )

                continue

            print(
                f"Transposing {stem_name} "
                f"{semitones:+g} semitones..."
            )

            # -------------------------------------------------
            # READ AUDIO
            # -------------------------------------------------

            audio, sample_rate = sf.read(
                str(source_file),
                always_2d=True,
            )

            audio = audio.astype(
                np.float32
            )

            # -------------------------------------------------
            # PITCH SHIFT EACH CHANNEL
            # -------------------------------------------------

            shifted_channels = []

            for channel_index in range(
                audio.shape[1]
            ):

                channel = audio[
                    :, channel_index
                ]

                shifted = (
                    librosa.effects.pitch_shift(
                        channel,
                        sr=sample_rate,
                        n_steps=semitones,
                    )
                )

                shifted_channels.append(
                    shifted
                )

            # Put channels back together
            shifted_audio = np.stack(
                shifted_channels,
                axis=1,
            )

            # -------------------------------------------------
            # SAVE
            # -------------------------------------------------

            sf.write(
                str(output_file),
                shifted_audio,
                sample_rate,
                subtype="PCM_16",
            )

            print(
                f"Created: {output_file}"
            )

    except Exception as e:

        print()
        print("TRANSPOSE ERROR:")
        print(e)
        print()

        raise HTTPException(
            status_code=500,
            detail=f"Transpose failed: {str(e)}",
        )

    # -----------------------------------------------------
    # BUILD RESPONSE
    # -----------------------------------------------------

    stems = {}

    for stem_name in stem_names:

        output_file = (
            transpose_dir /
            f"{stem_name}.wav"
        )

        if output_file.exists():

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"transpose_{shift_name}/"
                f"{stem_name}.wav"
            )

    print()
    print("Transpose complete!")
    print()

    return {
        "success": True,
        "job_id": job_id,
        "semitones": semitones,
        "stems": stems,
    }


# ---------------------------------------------------------
# EXPORT FINAL MIX AS MP3
# ---------------------------------------------------------

@app.post("/export")
async def export_mix(data: dict):

    job_id = data.get("job_id")

    if not job_id:

        raise HTTPException(
            status_code=400,
            detail="Missing job_id",
        )

    job_dir = OUTPUT_DIR / job_id

    if not job_dir.exists():

        raise HTTPException(
            status_code=404,
            detail="Song session not found",
        )

    stem_settings = data.get(
        "stems",
        {},
    )

    master_volume = float(
        data.get(
            "master_volume",
            1.0,
        )
    )

    stem_names = [
        "vocals",
        "drums",
        "bass",
        "other",
    ]

    audio_arrays = []

    sample_rate = None
    channel_count = None

    # -----------------------------------------------------
    # LOAD STEMS
    # -----------------------------------------------------

    for stem_name in stem_names:

        # Only use original stems for now.
        # This keeps the existing SAVE behaviour unchanged.
        matches = [
            path
            for path in job_dir.rglob(
                f"{stem_name}.wav"
            )
            if "transpose_" not in path.parts
        ]

        if not matches:
            continue

        stem_file = matches[0]

        settings = stem_settings.get(
            stem_name,
            {},
        )

        muted = bool(
            settings.get(
                "muted",
                False,
            )
        )

        volume = float(
            settings.get(
                "volume",
                1.0,
            )
        )

        if muted or volume <= 0:
            continue

        audio, sr = sf.read(
            str(stem_file),
            always_2d=True,
        )

        # -------------------------------------------------
        # SAMPLE RATE CHECK
        # -------------------------------------------------

        if sample_rate is None:

            sample_rate = sr
            channel_count = audio.shape[1]

        if sr != sample_rate:

            raise HTTPException(
                status_code=500,
                detail="Stem sample rates do not match",
            )

        if audio.shape[1] != channel_count:

            raise HTTPException(
                status_code=500,
                detail="Stem channel counts do not match",
            )

        audio = audio.astype(
            np.float32
        )

        # Apply stem volume
        audio *= volume

        audio_arrays.append(
            audio
        )

    # -----------------------------------------------------
    # NOTHING TO EXPORT
    # -----------------------------------------------------

    if not audio_arrays:

        raise HTTPException(
            status_code=400,
            detail="All stems are muted. Nothing to export.",
        )

    # -----------------------------------------------------
    # FIND LONGEST STEM
    # -----------------------------------------------------

    max_length = max(
        audio.shape[0]
        for audio in audio_arrays
    )

    mixed = np.zeros(
        (
            max_length,
            audio_arrays[0].shape[1],
        ),
        dtype=np.float32,
    )

    # -----------------------------------------------------
    # MIX
    # -----------------------------------------------------

    for audio in audio_arrays:

        if audio.shape[0] < max_length:

            padded = np.zeros(
                (
                    max_length,
                    audio.shape[1],
                ),
                dtype=np.float32,
            )

            padded[
                :audio.shape[0]
            ] = audio

            audio = padded

        mixed += audio

    # -----------------------------------------------------
    # MASTER VOLUME
    # -----------------------------------------------------

    mixed *= master_volume

    # -----------------------------------------------------
    # PREVENT CLIPPING
    # -----------------------------------------------------

    peak = np.max(
        np.abs(mixed)
    )

    if peak > 1.0:

        mixed = mixed / peak

    # -----------------------------------------------------
    # TEMPORARY WAV
    # -----------------------------------------------------

    temp_wav = (
        job_dir /
        "Musiq_Final_temp.wav"
    )

    export_file = (
        job_dir /
        "Musiq_Final.mp3"
    )

    sf.write(
        str(temp_wav),
        mixed,
        sample_rate,
        subtype="PCM_16",
    )

    # -----------------------------------------------------
    # FFMPEG
    # -----------------------------------------------------

    ffmpeg_path = shutil.which(
        "ffmpeg"
    )

    if ffmpeg_path is None:

        if temp_wav.exists():
            temp_wav.unlink()

        raise HTTPException(
            status_code=500,
            detail=(
                "FFmpeg is not installed "
                "or cannot be found."
            ),
        )

    ffmpeg_command = [
        ffmpeg_path,
        "-y",
        "-i",
        str(temp_wav),
        "-codec:a",
        "libmp3lame",
        "-b:a",
        "192k",
        str(export_file),
    ]

    try:

        print()
        print(
            "Creating final MP3..."
        )

        result = subprocess.run(
            ffmpeg_command,
            capture_output=True,
            text=True,
        )

        if result.returncode != 0:

            print(
                result.stderr
            )

            raise HTTPException(
                status_code=500,
                detail=(
                    "MP3 conversion failed."
                ),
            )

        print(
            "MP3 created successfully:"
        )

        print(export_file)

    except FileNotFoundError:

        raise HTTPException(
            status_code=500,
            detail=(
                "FFmpeg was not found."
            ),
        )

    finally:

        if temp_wav.exists():
            temp_wav.unlink()

    # -----------------------------------------------------
    # RETURN DOWNLOAD URL
    # -----------------------------------------------------

    return {
        "success": True,
        "filename": "Musiq_Final.mp3",
        "download_url": (
            f"/audio/{job_id}/"
            "Musiq_Final.mp3"
        ),
    }