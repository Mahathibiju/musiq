import subprocess
import sys
from pathlib import Path
import tkinter as tk
from tkinter import filedialog


# -----------------------------
# VOCALIS — SONG UPLOAD
# -----------------------------

print("\n🎵 VOCALIS — AI STEM SEPARATOR")
print("=" * 40)

# Create hidden Tkinter window
root = tk.Tk()
root.withdraw()

print("\n📁 Choose a song from your computer...")

file_path = filedialog.askopenfilename(
    title="Choose a song",
    filetypes=[
        ("Audio files", "*.mp3 *.wav *.m4a"),
        ("MP3 files", "*.mp3"),
        ("WAV files", "*.wav"),
        ("M4A files", "*.m4a"),
        ("All files", "*.*")
    ]
)

root.destroy()

# User cancelled
if not file_path:
    print("\n❌ No song selected.")
    sys.exit(0)

song = Path(file_path)

print("\n🎵 Selected:")
print(song.name)

print("\n🤖 Starting AI stem separation...")
print("This may take a few minutes.\n")

# Run Demucs
command = [
    sys.executable,
    "-m",
    "demucs",
    str(song)
]

result = subprocess.run(command)

# Check result
if result.returncode != 0:
    print("\n❌ Stem separation failed.")
    sys.exit(result.returncode)

print("\n" + "=" * 40)
print("✅ STEM SEPARATION COMPLETE!")
print("=" * 40)

print("\n🎧 Your stems:")

print("🎤 vocals.wav")
print("🥁 drums.wav")
print("🎸 bass.wav")
print("🎹 other.wav")

print("\n📁 Saved inside:")
print("separated/htdemucs/")