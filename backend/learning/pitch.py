import json
from pathlib import Path

import librosa
import numpy as np


def analyze_pitch(audio_path: str, output_path: str | None = None):
    """
    Analyze the pitch of an audio file.

    Returns:
        - duration
        - sample rate
        - pitch curve
        - confidence
    """

    audio_path = Path(audio_path)

    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    print(f"Loading: {audio_path}")

    # Load audio
    y, sr = librosa.load(
        str(audio_path),
        sr=None,
        mono=True,
    )

    duration = librosa.get_duration(
        y=y,
        sr=sr,
    )

    print(f"Duration: {duration:.2f} seconds")
    print(f"Sample rate: {sr}")

    # Detect fundamental frequency (pitch)
    f0, voiced_flag, voiced_prob = librosa.pyin(
        y,
        fmin=librosa.note_to_hz("C2"),
        fmax=librosa.note_to_hz("C7"),
        sr=sr,
        frame_length=2048,
        hop_length=512,
    )

    # Time value for every pitch frame
    times = librosa.times_like(
        f0,
        sr=sr,
        hop_length=512,
    )

    pitch_curve = []

    for time, frequency, voiced, confidence in zip(
        times,
        f0,
        voiced_flag,
        voiced_prob,
    ):

        if frequency is None or np.isnan(frequency):
            frequency_value = 0.0
        else:
            frequency_value = float(frequency)

        if confidence is None or np.isnan(confidence):
            confidence_value = 0.0
        else:
            confidence_value = float(confidence)

        pitch_curve.append(
            {
                "time": float(time),
                "frequency": frequency_value,
                "voiced": bool(voiced),
                "confidence": confidence_value,
            }
        )

    result = {
        "audio_file": audio_path.name,
        "duration": float(duration),
        "sample_rate": int(sr),
        "pitch_curve": pitch_curve,
    }

    # Save analysis if an output file was provided
    if output_path:
        output_path = Path(output_path)

        with open(output_path, "w") as f:
            json.dump(
                result,
                f,
                indent=2,
            )

        print(f"Analysis saved to: {output_path}")

    return result