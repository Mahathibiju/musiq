from pathlib import Path

import torch
from demucs.pretrained import get_model
from demucs.apply import apply_model
from demucs.audio import AudioFile


_model = None


def get_vocal_stem(audio_path: str, output_dir: str) -> str:
    """
    Separate an uploaded song and return the path
    to the vocal stem.

    This is used ONLY by the Learning module.
    """

    global _model

    audio_path = Path(audio_path)
    output_dir = Path(output_dir)

    output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    if not audio_path.exists():
        raise FileNotFoundError(
            f"Audio file not found: {audio_path}"
        )

    # Load Demucs model only once.
    if _model is None:
        _model = get_model(
            "htdemucs"
        )

        _model.cpu()

        _model.eval()

    # Load audio.
    wav = AudioFile(
        str(audio_path)
    ).read(
        streams=0,
        samplerate=_model.samplerate,
        channels=_model.audio_channels,
    )

    # Add batch dimension.
    wav = wav.unsqueeze(0)

    # Run separation.
    with torch.no_grad():
        sources = apply_model(
            _model,
            wav,
            device="cpu",
            progress=False,
        )

    # Demucs source order:
    # drums, bass, other, vocals

    source_names = _model.sources

    try:
        vocals_index = source_names.index(
            "vocals"
        )
    except ValueError:
        raise RuntimeError(
            "Demucs vocal source was not found."
        )

    vocals = sources[
        0,
        vocals_index,
    ]

    vocal_path = (
        output_dir /
        "vocals.wav"
    )

    # Save using torchaudio.
    import torchaudio

    torchaudio.save(
        str(vocal_path),
        vocals.cpu(),
        _model.samplerate,
    )

    return str(vocal_path)