from pathlib import Path
import subprocess
import time
import uuid
import shutil

import numpy as np
import librosa
import soundfile as sf

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles


# ============================================================
# APP
# ============================================================

app = FastAPI(title="Musiq Backend")


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ============================================================
# DIRECTORIES
# ============================================================

BASE_DIR = Path(__file__).resolve().parent

UPLOAD_DIR = BASE_DIR / "uploads"
OUTPUT_DIR = BASE_DIR / "outputs"

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# Serve generated audio
app.mount(
    "/audio",
    StaticFiles(directory=str(OUTPUT_DIR)),
    name="audio",
)


# ============================================================
# BASIC ROUTES
# ============================================================

@app.get("/")
def root():
    return {
        "app": "Musiq",
        "status": "running",
    }


@app.get("/health")
def health():
    return {
        "success": True,
        "message": "Musiq backend is running",
    }


# ============================================================
# STEM CONFIGURATION
# ============================================================

STEM_NAMES = [
    "vocals",
    "drums",
    "bass",
    "other",
]


# ============================================================
# FIND ORIGINAL STEM
# ============================================================

def get_original_stem(
    job_dir: Path,
    stem_name: str,
):

    possible_files = [
        job_dir / f"{stem_name}.wav",
        job_dir / f"{stem_name}.mp3",
        job_dir / f"{stem_name}.flac",
    ]

    for file_path in possible_files:

        if file_path.exists():
            return file_path

    return None


# ============================================================
# STEM URL
# ============================================================

def get_stem_url(
    job_id: str,
    stem_name: str,
):

    return (
        f"/audio/{job_id}/{stem_name}.wav"
    )


# ============================================================
# LOAD AUDIO AS CHANNELS x SAMPLES
# ============================================================

def load_audio(
    file_path: Path,
):

    audio, sample_rate = librosa.load(
        str(file_path),
        sr=None,
        mono=False,
    )

    # Convert mono -> 1 x samples
    if audio.ndim == 1:

        audio = audio[
            np.newaxis,
            :
        ]

    return (
        audio.astype(np.float32),
        sample_rate,
    )


# ============================================================
# SAVE AUDIO
# ============================================================

def save_audio(
    file_path: Path,
    audio: np.ndarray,
    sample_rate: int,
):

    # librosa format:
    # channels x samples

    # soundfile expects:
    # samples x channels

    sf.write(
        str(file_path),
        audio.T,
        sample_rate,
    )


# ============================================================
# SEPARATE SONG INTO 4 STEMS
# ============================================================

@app.post("/separate")
async def separate_song(
    file: UploadFile = File(...),
):

    if not file.filename:

        raise HTTPException(
            status_code=400,
            detail="No filename supplied.",
        )

    job_id = str(
        uuid.uuid4()
    )

    job_dir = (
        OUTPUT_DIR / job_id
    )

    job_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    extension = Path(
        file.filename
    ).suffix.lower()

    if not extension:

        extension = ".wav"

    input_file = (
        UPLOAD_DIR
        / f"{job_id}{extension}"
    )

    try:

        # ----------------------------------------------------
        # SAVE UPLOADED SONG
        # ----------------------------------------------------

        contents = await file.read()

        with open(
            input_file,
            "wb",
        ) as f:

            f.write(contents)

        # ----------------------------------------------------
        # RUN DEMUCS
        #
        # Produces:
        #
        # vocals
        # drums
        # bass
        # other
        # ----------------------------------------------------

        result = subprocess.run(

            [
                "python3",
                "-m",
                "demucs",
                "--name",
                "htdemucs",
                "-o",
                str(job_dir),
                str(input_file),
            ],

            capture_output=True,
            text=True,
        )

        if result.returncode != 0:

            raise HTTPException(
                status_code=500,
                detail=(
                    "Demucs failed.\n\n"
                    + result.stderr
                ),
            )

        # ----------------------------------------------------
        # FIND DEMUCS WAV FILES
        # ----------------------------------------------------

        possible_files = list(
            job_dir.rglob("*.wav")
        )

        if not possible_files:

            raise HTTPException(
                status_code=500,
                detail=(
                    "Demucs finished but "
                    "no WAV files were found."
                ),
            )

        # ----------------------------------------------------
        # COPY FOUR STEMS
        # ----------------------------------------------------

        stems = {}

        for stem_name in STEM_NAMES:

            stem_file = None

            for candidate in possible_files:

                if (
                    candidate.stem.lower()
                    == stem_name
                ):

                    stem_file = candidate
                    break

            if stem_file is None:
                continue

            destination = (
                job_dir
                / f"{stem_name}.wav"
            )

            if stem_file != destination:

                shutil.copy2(
                    stem_file,
                    destination,
                )

            stems[stem_name] = (
                get_stem_url(
                    job_id,
                    stem_name,
                )
            )

        # ----------------------------------------------------
        # VERIFY ALL FOUR STEMS
        # ----------------------------------------------------

        missing = [
            stem
            for stem in STEM_NAMES
            if stem not in stems
        ]

        if missing:

            raise HTTPException(
                status_code=500,
                detail=(
                    "Demucs did not produce "
                    "all four stems. "
                    f"Missing: {missing}"
                ),
            )

        return {

            "success": True,

            "job_id": job_id,

            "filename":
                file.filename,

            "stems":
                stems,

            "semitones": 0,
        }

    except HTTPException:

        raise

    except Exception as e:

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )


# ============================================================
# TRANSPOSE STEMS
# ============================================================

@app.post("/transpose")
async def transpose_stems(
    data: dict,
):

    job_id = data.get(
        "job_id"
    )

    if not job_id:

        raise HTTPException(
            status_code=400,
            detail="job_id is required.",
        )

    try:

        semitones = float(
            data.get(
                "semitones",
                0,
            )
        )

    except Exception:

        raise HTTPException(
            status_code=400,
            detail="Invalid semitone value.",
        )

    # --------------------------------------------------------
    # ONLY ALLOW UI RANGE
    # --------------------------------------------------------

    if (
        semitones < -12
        or semitones > 12
    ):

        raise HTTPException(
            status_code=400,
            detail=(
                "Semitones must be between "
                "-12 and +12."
            ),
        )

    job_dir = (
        OUTPUT_DIR / job_id
    )

    if not job_dir.exists():

        raise HTTPException(
            status_code=404,
            detail="Job not found.",
        )

    semitones = int(
        round(semitones)
    )

    # --------------------------------------------------------
    # ZERO = ORIGINAL AUDIO
    # --------------------------------------------------------

    if semitones == 0:

        stems = {}

        for stem_name in STEM_NAMES:

            stem_file = get_original_stem(
                job_dir,
                stem_name,
            )

            if stem_file:

                stems[stem_name] = (
                    get_stem_url(
                        job_id,
                        stem_name,
                    )
                )

        if len(stems) != 4:

            raise HTTPException(
                status_code=500,
                detail=(
                    "Original four stems "
                    "are missing."
                ),
            )

        return {

            "success": True,

            "job_id": job_id,

            "semitones": 0,

            "reset": True,

            "source": "original",

            "stems": stems,
        }

    # --------------------------------------------------------
    # TRANSPOSE DIRECTORY
    # --------------------------------------------------------

    transpose_dir = (
        job_dir / "transpose"
    )

    transpose_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    stems = {}

    for stem_name in STEM_NAMES:

        source_file = get_original_stem(
            job_dir,
            stem_name,
        )

        if source_file is None:
            continue

        output_file = (
            transpose_dir
            / f"{stem_name}_{semitones}.wav"
        )

        # ----------------------------------------------------
        # USE CACHED VERSION
        # ----------------------------------------------------

        if output_file.exists():

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"transpose/"
                f"{output_file.name}"
            )

            continue

        try:

            # ------------------------------------------------
            # LOAD ORIGINAL STEM
            # ------------------------------------------------

            audio, sample_rate = (
                load_audio(
                    source_file
                )
            )

            shifted_channels = []

            # ------------------------------------------------
            # PITCH SHIFT EACH CHANNEL
            # ------------------------------------------------

            for channel in audio:

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

            # ------------------------------------------------
            # REBUILD CHANNEL ARRAY
            # ------------------------------------------------

            shifted_audio = np.stack(
                shifted_channels,
                axis=0,
            )

            # ------------------------------------------------
            # SAVE
            # ------------------------------------------------

            save_audio(
                output_file,
                shifted_audio,
                sample_rate,
            )

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"transpose/"
                f"{output_file.name}"
            )

        except Exception as e:

            raise HTTPException(
                status_code=500,
                detail=(
                    f"Transpose failed "
                    f"for {stem_name}: "
                    f"{str(e)}"
                ),
            )

    # --------------------------------------------------------
    # VERIFY
    # --------------------------------------------------------

    missing = [
        stem
        for stem in STEM_NAMES
        if stem not in stems
    ]

    if missing:

        raise HTTPException(
            status_code=500,
            detail=(
                "Transpose failed. "
                f"Missing stems: {missing}"
            ),
        )

    return {

        "success": True,

        "job_id": job_id,

        "semitones": semitones,

        "reset": False,

        "source": "transposed",

        "stems": stems,
    }


# ============================================================
# TEMPO
#
# NEW SCALE:
#
# -100 = extremely slow
#    0  = original tempo
#  +100 = 2x speed
#
# IMPORTANT:
# -100 would produce rate = 0, which is invalid.
# Therefore the backend accepts -99 as the slowest
# actual processing value.
#
# Examples:
#
# -99 -> 1% speed
# -75 -> 25% speed
# -50 -> 50% speed
# -25 -> 75% speed
#   0 -> 100% speed
# +25 -> 125% speed
# +50 -> 150% speed
# +75 -> 175% speed
# +100 -> 200% speed
#
# ============================================================

@app.post("/tempo")
async def change_tempo(
    data: dict,
):

    job_id = data.get(
        "job_id"
    )

    if not job_id:

        raise HTTPException(
            status_code=400,
            detail="job_id is required.",
        )

    try:

        tempo_value = float(
            data.get(
                "tempo_percent",
                0,
            )
        )

    except Exception:

        raise HTTPException(
            status_code=400,
            detail="Invalid tempo value.",
        )

    # --------------------------------------------------------
    # NEW UI RANGE
    #
    # -100 ... +100
    # --------------------------------------------------------

    if (
        tempo_value < -100
        or tempo_value > 100
    ):

        raise HTTPException(
            status_code=400,
            detail=(
                "Tempo must be between "
                "-100 and +100."
            ),
        )

    job_dir = (
        OUTPUT_DIR / job_id
    )

    if not job_dir.exists():

        raise HTTPException(
            status_code=404,
            detail="Job not found.",
        )

    # --------------------------------------------------------
    # NORMALIZE TO INTEGER
    # --------------------------------------------------------

    tempo_value = int(
        round(tempo_value)
    )

    # --------------------------------------------------------
    # ZERO = ORIGINAL AUDIO
    # --------------------------------------------------------

    if tempo_value == 0:

        stems = {}

        for stem_name in STEM_NAMES:

            stem_file = get_original_stem(
                job_dir,
                stem_name,
            )

            if stem_file:

                stems[stem_name] = (
                    get_stem_url(
                        job_id,
                        stem_name,
                    )
                )

        if len(stems) != 4:

            raise HTTPException(
                status_code=500,
                detail=(
                    "Original four stems "
                    "are missing."
                ),
            )

        return {

            "success": True,

            "job_id": job_id,

            "tempo_percent": 0,

            "reset": True,

            "source": "original",

            "stems": stems,
        }

    # --------------------------------------------------------
    # -100 CANNOT BE USED DIRECTLY
    #
    # A rate of 0 means infinite/invalid stretching.
    #
    # We use 0.01 for -100.
    # --------------------------------------------------------

    if tempo_value == -100:

        rate = 0.01

    else:

        rate = (
            1.0
            + tempo_value / 100.0
        )

    # --------------------------------------------------------
    # TEMPO DIRECTORY
    # --------------------------------------------------------

    tempo_dir = (
        job_dir / "tempo"
    )

    tempo_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    stems = {}

    # --------------------------------------------------------
    # PROCESS ALL FOUR STEMS
    # --------------------------------------------------------

    for stem_name in STEM_NAMES:

        source_file = get_original_stem(
            job_dir,
            stem_name,
        )

        if source_file is None:
            continue

        output_file = (
            tempo_dir
            / f"{stem_name}_{tempo_value}.wav"
        )

        # ----------------------------------------------------
        # USE CACHED VERSION
        # ----------------------------------------------------

        if output_file.exists():

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"tempo/"
                f"{output_file.name}"
            )

            continue

        try:

            # ------------------------------------------------
            # LOAD ORIGINAL STEM
            # ------------------------------------------------

            audio, sample_rate = (
                load_audio(
                    source_file
                )
            )

            stretched_channels = []

            # ------------------------------------------------
            # TIME-STRETCH EACH CHANNEL
            # ------------------------------------------------

            for channel in audio:

                stretched = (
                    librosa.effects.time_stretch(
                        channel,
                        rate=rate,
                    )
                )

                stretched_channels.append(
                    stretched
                )

            # ------------------------------------------------
            # REBUILD CHANNEL ARRAY
            # ------------------------------------------------

            stretched_audio = np.stack(
                stretched_channels,
                axis=0,
            )

            # ------------------------------------------------
            # SAVE
            # ------------------------------------------------

            save_audio(
                output_file,
                stretched_audio,
                sample_rate,
            )

            stems[stem_name] = (
                f"/audio/{job_id}/"
                f"tempo/"
                f"{output_file.name}"
            )

        except Exception as e:

            raise HTTPException(
                status_code=500,
                detail=(
                    f"Tempo failed "
                    f"for {stem_name}: "
                    f"{str(e)}"
                ),
            )

    # --------------------------------------------------------
    # VERIFY
    # --------------------------------------------------------

    missing = [
        stem
        for stem in STEM_NAMES
        if stem not in stems
    ]

    if missing:

        raise HTTPException(
            status_code=500,
            detail=(
                "Tempo failed. "
                f"Missing stems: {missing}"
            ),
        )

    return {

        "success": True,

        "job_id": job_id,

        "tempo_percent":
            tempo_value,

        "reset": False,

        "source": "tempo",

        "rate": rate,

        "stems": stems,
    }


# ============================================================
# EXPORT FINAL MIX
# ============================================================

@app.post("/export")
async def export_mix(
    data: dict,
):

    job_id = data.get(
        "job_id"
    )

    if not job_id:

        raise HTTPException(
            status_code=400,
            detail="job_id is required.",
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

    semitones = int(
        round(
            float(
                data.get(
                    "semitones",
                    0,
                )
            )
        )
    )

    job_dir = (
        OUTPUT_DIR / job_id
    )

    if not job_dir.exists():

        raise HTTPException(
            status_code=404,
            detail="Job not found.",
        )

    # --------------------------------------------------------
    # LOAD CURRENT PITCH VERSION
    # --------------------------------------------------------

    audio_arrays = []
    sample_rates = []

    for stem_name in STEM_NAMES:

        # ----------------------------------------------------
        # ORIGINAL
        # ----------------------------------------------------

        if semitones == 0:

            stem_file = get_original_stem(
                job_dir,
                stem_name,
            )

        # ----------------------------------------------------
        # TRANSPOSED
        # ----------------------------------------------------

        else:

            stem_file = (
                job_dir
                / "transpose"
                / f"{stem_name}_{semitones}.wav"
            )

            if not stem_file.exists():

                raise HTTPException(
                    status_code=400,
                    detail=(
                        f"Transposed {stem_name} "
                        "does not exist. "
                        "Apply transpose first."
                    ),
                )

        if (
            not stem_file
            or not stem_file.exists()
        ):

            continue

        try:

            audio, sample_rate = (
                load_audio(
                    stem_file
                )
            )

            sample_rates.append(
                sample_rate
            )

            # ------------------------------------------------
            # STEM SETTINGS
            # ------------------------------------------------

            settings = (
                stem_settings.get(
                    stem_name,
                    {},
                )
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

            if muted:
                volume = 0.0

            audio *= volume

            audio_arrays.append(
                audio
            )

        except Exception as e:

            raise HTTPException(
                status_code=500,
                detail=(
                    f"Could not load "
                    f"{stem_name}: "
                    f"{str(e)}"
                ),
            )

    # --------------------------------------------------------
    # NOTHING TO EXPORT
    # --------------------------------------------------------

    if not audio_arrays:

        raise HTTPException(
            status_code=400,
            detail="No audio stems found.",
        )

    # --------------------------------------------------------
    # LONGEST STEM
    # --------------------------------------------------------

    max_length = max(
        audio.shape[1]
        for audio in audio_arrays
    )

    max_channels = max(
        audio.shape[0]
        for audio in audio_arrays
    )

    # --------------------------------------------------------
    # CREATE MIX
    # --------------------------------------------------------

    mixed = np.zeros(
        (
            max_channels,
            max_length,
        ),
        dtype=np.float32,
    )

    for audio in audio_arrays:

        channels = audio.shape[0]
        length = audio.shape[1]

        if (
            channels == 1
            and max_channels > 1
        ):

            padded = np.repeat(
                audio,
                max_channels,
                axis=0,
            )

        else:

            padded = audio

        mixed[
            :padded.shape[0],
            :length,
        ] += padded

    # --------------------------------------------------------
    # MASTER VOLUME
    # --------------------------------------------------------

    mixed *= master_volume

    # --------------------------------------------------------
    # PREVENT CLIPPING
    # --------------------------------------------------------

    peak = np.max(
        np.abs(mixed)
    )

    if peak > 1.0:

        mixed /= peak

    # --------------------------------------------------------
    # TEMP WAV
    # --------------------------------------------------------

    temp_wav = (
        job_dir
        / "Musiq_Final.wav"
    )

    export_file = (
        job_dir
        / "Musiq_Final.mp3"
    )

    save_audio(
        temp_wav,
        mixed,
        sample_rates[0],
    )

    # --------------------------------------------------------
    # FIND FFMPEG
    # --------------------------------------------------------

    ffmpeg_path = shutil.which(
        "ffmpeg"
    )

    if not ffmpeg_path:

        raise HTTPException(
            status_code=500,
            detail=(
                "FFmpeg is not installed "
                "or not available in PATH."
            ),
        )

    # --------------------------------------------------------
    # WAV -> MP3
    # --------------------------------------------------------

    result = subprocess.run(

        [
            ffmpeg_path,
            "-y",
            "-i",
            str(temp_wav),
            "-codec:a",
            "libmp3lame",
            "-q:a",
            "2",
            str(export_file),
        ],

        capture_output=True,
        text=True,
    )

    if result.returncode != 0:

        raise HTTPException(
            status_code=500,
            detail=(
                "FFmpeg export failed.\n\n"
                + result.stderr
            ),
        )

    # --------------------------------------------------------
    # RESPONSE
    # --------------------------------------------------------

    return {

        "success": True,

        "filename":
            "Musiq_Final.mp3",

        "download_url": (
            f"/audio/{job_id}/"
            f"Musiq_Final.mp3"
        ),

        "semitones":
            semitones,

        "cache_version":
            time.time_ns(),
    }