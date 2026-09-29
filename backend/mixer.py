import tkinter as tk
from tkinter import messagebox, filedialog
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf


ROOT = Path(__file__).parent
SEPARATED = ROOT / "separated" / "htdemucs"


class VocalisMixer:

    def __init__(self, root):
        self.root = root

        self.root.title("Vocalis — Stem Mixer")
        self.root.geometry("950x720")
        self.root.configure(bg="#0B0C0F")

        self.files = {}

        self.volume_vars = {}
        self.mute_vars = {}
        self.solo_vars = {}
        self.volume_labels = {}

        self.stream = None
        self.playing = False

        self.master_volume = 1.0
        self.karaoke_mode = False

        self.load_latest_song()
        self.build_interface()

    # ---------------------------------------------------------
    # FIND LATEST SEPARATED SONG
    # ---------------------------------------------------------

    def load_latest_song(self):

        if not SEPARATED.exists():

            messagebox.showerror(
                "Vocalis",
                "No separated songs found.\n\n"
                "Run separate.py first."
            )

            self.root.destroy()
            return

        folders = [
            folder
            for folder in SEPARATED.iterdir()
            if folder.is_dir()
        ]

        if not folders:

            messagebox.showerror(
                "Vocalis",
                "No separated songs found.\n\n"
                "Run separate.py first."
            )

            self.root.destroy()
            return

        song_folder = max(
            folders,
            key=lambda folder: folder.stat().st_mtime
        )

        self.song_folder = song_folder
        self.song_name = song_folder.name

        print()
        print("=" * 55)
        print("🎵 VOCALIS")
        print("=" * 55)

        print(f"Loading: {self.song_name}")
        print()

        stem_names = [
            "vocals",
            "drums",
            "bass",
            "other"
        ]

        for name in stem_names:

            path = song_folder / f"{name}.wav"

            if not path.exists():

                print(f"⚠️ Missing: {name}.wav")
                continue

            try:

                audio_file = sf.SoundFile(
                    path,
                    mode="r"
                )

                self.files[name] = audio_file

                self.volume_vars[name] = tk.DoubleVar(
                    value=1.0
                )

                self.mute_vars[name] = tk.BooleanVar(
                    value=False
                )

                self.solo_vars[name] = tk.BooleanVar(
                    value=False
                )

                print(f"✅ Loaded: {name}.wav")

            except Exception as error:

                print(f"❌ Could not open {name}.wav")
                print(error)

        if not self.files:

            messagebox.showerror(
                "Vocalis",
                "No WAV stems could be opened."
            )

            self.root.destroy()
            return

        first_file = next(
            iter(self.files.values())
        )

        self.sample_rate = first_file.samplerate

        self.total_frames = max(
            audio_file.frames
            for audio_file in self.files.values()
        )

        print()
        print("✅ Audio ready.")
        print(f"Sample rate: {self.sample_rate}")
        print(f"Stems loaded: {len(self.files)}")

        print("=" * 55)
        print()

    # ---------------------------------------------------------
    # BUILD UI
    # ---------------------------------------------------------

    def build_interface(self):

        # HEADER
        header = tk.Frame(
            self.root,
            bg="#0B0C0F"
        )

        header.pack(
            fill="x",
            padx=30,
            pady=(25, 5)
        )

        title = tk.Label(
            header,
            text="VOCALIS",
            font=("Helvetica", 25, "bold"),
            fg="#FFFFFF",
            bg="#0B0C0F"
        )

        title.pack(side="left")

        mixer_title = tk.Label(
            header,
            text="  STEM MIXER",
            font=("Helvetica", 15),
            fg="#A855F7",
            bg="#0B0C0F"
        )

        mixer_title.pack(
            side="left",
            pady=(7, 0)
        )

        # SONG NAME
        self.song_label = tk.Label(
            self.root,
            text=self.song_name,
            font=("Helvetica", 13),
            fg="#AAAAAA",
            bg="#0B0C0F"
        )

        self.song_label.pack(
            anchor="w",
            padx=30
        )

        # STATUS
        self.status_label = tk.Label(
            self.root,
            text="Ready",
            font=("Helvetica", 11, "bold"),
            fg="#AAAAAA",
            bg="#0B0C0F"
        )

        self.status_label.pack(
            anchor="w",
            padx=30,
            pady=(5, 0)
        )

        # TRANSPORT
        transport = tk.Frame(
            self.root,
            bg="#16181D"
        )

        transport.pack(
            fill="x",
            padx=30,
            pady=20
        )

        play_button = tk.Button(
            transport,
            text="▶  PLAY / PAUSE",
            command=self.toggle_play,
            font=("Helvetica", 11, "bold"),
            bg="#A855F7",
            fg="white",
            activebackground="#9333EA",
            relief="flat",
            padx=20,
            pady=10
        )

        play_button.pack(
            side="left",
            padx=10,
            pady=12
        )

        stop_button = tk.Button(
            transport,
            text="■  STOP",
            command=self.stop,
            font=("Helvetica", 11, "bold"),
            bg="#292C33",
            fg="white",
            activebackground="#33363D",
            relief="flat",
            padx=20,
            pady=10
        )

        stop_button.pack(
            side="left",
            padx=5
        )

        # MASTER
        master_label = tk.Label(
            transport,
            text="MASTER",
            font=("Helvetica", 10, "bold"),
            fg="white",
            bg="#16181D"
        )

        master_label.pack(
            side="left",
            padx=(45, 5)
        )

        self.master_slider = tk.Scale(
            transport,
            from_=0,
            to=1,
            resolution=0.01,
            orient="horizontal",
            length=160,
            showvalue=False,
            bg="#16181D",
            fg="white",
            troughcolor="#33363D",
            highlightthickness=0,
            command=self.change_master
        )

        self.master_slider.set(1)

        self.master_slider.pack(
            side="left"
        )

        # -----------------------------------------------------
        # KARAOKE BUTTONS
        # -----------------------------------------------------

        karaoke_frame = tk.Frame(
            self.root,
            bg="#0B0C0F"
        )

        karaoke_frame.pack(
            fill="x",
            padx=30,
            pady=(0, 10)
        )

        self.remove_vocals_button = tk.Button(
            karaoke_frame,
            text="🔇  REMOVE VOCALS",
            command=self.remove_vocals,
            font=("Helvetica", 11, "bold"),
            bg="#FF40DA",
            fg="white",
            activebackground="#E635C5",
            relief="flat",
            padx=18,
            pady=10
        )

        self.remove_vocals_button.pack(
            side="left",
            padx=(0, 10)
        )

        self.export_button = tk.Button(
            karaoke_frame,
            text="💾  EXPORT KARAOKE",
            command=self.export_karaoke,
            font=("Helvetica", 11, "bold"),
            bg="#FF681A",
            fg="white",
            activebackground="#E55A12",
            relief="flat",
            padx=18,
            pady=10
        )

        self.export_button.pack(
            side="left"
        )

        # -----------------------------------------------------
        # MIXER
        # -----------------------------------------------------

        mixer = tk.Frame(
            self.root,
            bg="#0B0C0F"
        )

        mixer.pack(
            fill="both",
            expand=True,
            padx=30
        )

        self.track_frame = mixer

        self.create_track(
            "vocals",
            "🎤  VOCALS",
            "#FF40DA"
        )

        self.create_track(
            "drums",
            "🥁  DRUMS",
            "#FF681A"
        )

        self.create_track(
            "bass",
            "🎸  BASS",
            "#A855F7"
        )

        self.create_track(
            "other",
            "🎹  OTHER",
            "#38BDF8"
        )

    # ---------------------------------------------------------
    # CREATE TRACK
    # ---------------------------------------------------------

    def create_track(
        self,
        name,
        display_name,
        accent
    ):

        card = tk.Frame(
            self.track_frame,
            bg="#16181D",
            height=105
        )

        card.pack(
            fill="x",
            pady=6
        )

        card.pack_propagate(False)

        label = tk.Label(
            card,
            text=display_name,
            font=("Helvetica", 13, "bold"),
            fg=accent,
            bg="#16181D",
            width=16,
            anchor="w"
        )

        label.pack(
            side="left",
            padx=(15, 5)
        )

        # MUTE
        mute = tk.Checkbutton(
            card,
            text="M",
            variable=self.mute_vars[name],
            font=("Helvetica", 10, "bold"),
            fg="white",
            bg="#16181D",
            selectcolor="#FF3B5C",
            activebackground="#16181D",
            activeforeground="white"
        )

        mute.pack(
            side="left",
            padx=5
        )

        # SOLO
        solo = tk.Checkbutton(
            card,
            text="S",
            variable=self.solo_vars[name],
            font=("Helvetica", 10, "bold"),
            fg="white",
            bg="#16181D",
            selectcolor="#A855F7",
            activebackground="#16181D",
            activeforeground="white"
        )

        solo.pack(
            side="left",
            padx=5
        )

        # VOLUME
        slider = tk.Scale(
            card,
            from_=0,
            to=1,
            resolution=0.01,
            orient="horizontal",
            length=350,
            showvalue=False,
            bg="#16181D",
            fg="white",
            troughcolor="#33363D",
            highlightthickness=0,
            command=lambda value, n=name:
                self.change_volume(n, value)
        )

        slider.set(1)

        slider.pack(
            side="left",
            padx=20
        )

        # PERCENTAGE
        percentage = tk.Label(
            card,
            text="100%",
            font=("Helvetica", 10),
            fg="#AAAAAA",
            bg="#16181D",
            width=6
        )

        percentage.pack(
            side="left"
        )

        self.volume_labels[name] = percentage

    # ---------------------------------------------------------
    # VOLUME
    # ---------------------------------------------------------

    def change_volume(
        self,
        name,
        value
    ):

        value = float(value)

        self.volume_vars[name].set(value)

        percentage = int(value * 100)

        self.volume_labels[name].config(
            text=f"{percentage}%"
        )

    # ---------------------------------------------------------
    # MASTER
    # ---------------------------------------------------------

    def change_master(
        self,
        value
    ):

        self.master_volume = float(value)

    # ---------------------------------------------------------
    # SOLO
    # ---------------------------------------------------------

    def has_solo(self):

        return any(
            self.solo_vars[name].get()
            for name in self.files
        )

    # ---------------------------------------------------------
    # AUDIO CALLBACK
    # ---------------------------------------------------------

    def audio_callback(
        self,
        outdata,
        frames,
        time,
        status
    ):

        if status:
            print("Audio status:", status)

        output = np.zeros(
            (frames, 2),
            dtype=np.float32
        )

        solo_active = self.has_solo()

        something_playing = False

        for name, audio_file in self.files.items():

            if self.mute_vars[name].get():
                continue

            if (
                solo_active
                and not self.solo_vars[name].get()
            ):
                continue

            chunk = audio_file.read(
                frames,
                dtype="float32",
                always_2d=True
            )

            if len(chunk) == 0:
                continue

            something_playing = True

            if chunk.shape[1] == 1:

                chunk = np.repeat(
                    chunk,
                    2,
                    axis=1
                )

            if chunk.shape[1] > 2:

                chunk = chunk[:, :2]

            volume = self.volume_vars[name].get()

            output[:len(chunk)] += (
                chunk * volume
            )

        output *= self.master_volume

        output = np.clip(
            output,
            -1,
            1
        )

        outdata[:] = 0

        outdata[:len(output)] = output

        if not something_playing:

            raise sd.CallbackStop

    # ---------------------------------------------------------
    # PLAY
    # ---------------------------------------------------------

    def play(self):

        if self.playing:
            return

        self.playing = True

        for audio_file in self.files.values():

            audio_file.seek(0)

        self.stream = sd.OutputStream(
            samplerate=self.sample_rate,
            channels=2,
            dtype="float32",
            callback=self.audio_callback
        )

        self.stream.start()

        self.status_label.config(
            text="▶ Playing",
            fg="#A855F7"
        )

    # ---------------------------------------------------------
    # PAUSE
    # ---------------------------------------------------------

    def pause(self):

        if self.stream:

            self.stream.stop()
            self.stream.close()

            self.stream = None

        self.playing = False

        self.status_label.config(
            text="Paused",
            fg="#AAAAAA"
        )

    # ---------------------------------------------------------
    # PLAY / PAUSE
    # ---------------------------------------------------------

    def toggle_play(self):

        if self.playing:

            self.pause()

        else:

            self.play()

    # ---------------------------------------------------------
    # STOP
    # ---------------------------------------------------------

    def stop(self):

        self.pause()

        for audio_file in self.files.values():

            audio_file.seek(0)

        self.status_label.config(
            text="Stopped",
            fg="#AAAAAA"
        )

    # ---------------------------------------------------------
    # REMOVE VOCALS
    # ---------------------------------------------------------

    def remove_vocals(self):

        if "vocals" not in self.volume_vars:
            return

        # Set vocals to zero
        self.volume_vars["vocals"].set(0)

        # Find the vocal slider visually and update label
        self.volume_labels["vocals"].config(
            text="0%"
        )

        # Clear solo mode
        for name in self.solo_vars:

            self.solo_vars[name].set(False)

        self.karaoke_mode = True

        self.status_label.config(
            text="🎧 Karaoke Mode ON — Vocals Removed",
            fg="#FF40DA"
        )

        messagebox.showinfo(
            "Vocalis Karaoke",
            "Vocals have been removed from the mix.\n\n"
            "You can now adjust the instrumental stems "
            "and export your karaoke track."
        )

    # ---------------------------------------------------------
    # EXPORT KARAOKE
    # ---------------------------------------------------------

    def export_karaoke(self):

        if not self.files:

            messagebox.showerror(
                "Vocalis",
                "No audio stems are loaded."
            )

            return

        # Stop playback before exporting
        if self.playing:

            self.stop()

        # Save dialog
        default_name = (
            self.song_name
            + "_Karaoke.wav"
        )

        output_path = filedialog.asksaveasfilename(
            title="Export Vocalis Karaoke",
            defaultextension=".wav",
            initialfile=default_name,
            filetypes=[
                (
                    "WAV audio",
                    "*.wav"
                )
            ]
        )

        if not output_path:

            return

        self.status_label.config(
            text="⏳ Rendering karaoke...",
            fg="#FF681A"
        )

        self.root.update_idletasks()

        try:

            self.render_mix(output_path)

            self.status_label.config(
                text="✅ Karaoke exported successfully!",
                fg="#4ADE80"
            )

            messagebox.showinfo(
                "Vocalis",
                "🎉 Karaoke export complete!\n\n"
                f"Saved as:\n{output_path}"
            )

        except Exception as error:

            self.status_label.config(
                text="❌ Export failed",
                fg="#FF3B5C"
            )

            messagebox.showerror(
                "Export Error",
                f"Could not export karaoke:\n\n{error}"
            )

    # ---------------------------------------------------------
    # RENDER MIX
    # ---------------------------------------------------------

    def render_mix(
        self,
        output_path
    ):

        # Open fresh copies of the stems.
        render_files = {}

        try:

            for name in self.files:

                original_path = (
                    self.song_folder
                    / f"{name}.wav"
                )

                render_files[name] = sf.SoundFile(
                    original_path,
                    mode="r"
                )

            # Determine output length
            total_frames = max(
                file.frames
                for file in render_files.values()
            )

            samplerate = next(
                iter(render_files.values())
            ).samplerate

            # Create output WAV
            with sf.SoundFile(
                output_path,
                mode="w",
                samplerate=samplerate,
                channels=2,
                subtype="PCM_16"
            ) as output_file:

                chunk_size = 65536

                frames_done = 0

                while frames_done < total_frames:

                    frames_to_read = min(
                        chunk_size,
                        total_frames - frames_done
                    )

                    mixed = np.zeros(
                        (frames_to_read, 2),
                        dtype=np.float32
                    )

                    solo_active = self.has_solo()

                    for name, audio_file in render_files.items():

                        # MUTE
                        if self.mute_vars[name].get():
                            continue

                        # SOLO
                        if (
                            solo_active
                            and not self.solo_vars[name].get()
                        ):
                            continue

                        chunk = audio_file.read(
                            frames_to_read,
                            dtype="float32",
                            always_2d=True
                        )

                        if len(chunk) == 0:
                            continue

                        # Convert mono → stereo
                        if chunk.shape[1] == 1:

                            chunk = np.repeat(
                                chunk,
                                2,
                                axis=1
                            )

                        # Keep first two channels
                        if chunk.shape[1] > 2:

                            chunk = chunk[:, :2]

                        volume = (
                            self.volume_vars[name].get()
                        )

                        mixed[:len(chunk)] += (
                            chunk * volume
                        )

                    # Master volume
                    mixed *= self.master_volume

                    # Prevent clipping
                    mixed = np.clip(
                        mixed,
                        -1,
                        1
                    )

                    output_file.write(mixed)

                    frames_done += frames_to_read

                    # Update status
                    progress = (
                        frames_done
                        / total_frames
                    ) * 100

                    self.status_label.config(
                        text=(
                            f"⏳ Rendering karaoke... "
                            f"{progress:.0f}%"
                        )
                    )

                    self.root.update_idletasks()

        finally:

            # Close render files
            for audio_file in render_files.values():

                try:
                    audio_file.close()

                except Exception:
                    pass


# =============================================================
# START VOCALIS
# =============================================================

root = tk.Tk()

app = VocalisMixer(root)

root.mainloop()



