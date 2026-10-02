import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

class LearningPage extends StatefulWidget {
  const LearningPage({super.key});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  // ============================================================
  // AUDIO
  // ============================================================

  final AudioPlayer audioPlayer = AudioPlayer();
  final AudioRecorder microphone = AudioRecorder();

  StreamSubscription<Uint8List>? micSubscription;

  bool isPlaying = false;
  bool isCountingDown = false;
  bool isSinging = false;

  int countdownValue = 0;

  // ============================================================
  // SONG
  // ============================================================

  String? selectedSongName;
  Uint8List? selectedSongBytes;

  bool isAnalyzing = false;
  String? analysisStatus;

  // ============================================================
  // REFERENCE PITCH
  // ============================================================

  List<PitchPoint> pitchCurve = [];

  double currentTime = 0.0;
  double songDuration = 0.0;

  static const double visibleWindow = 6.0;

  // ============================================================
  // USER LIVE PITCH
  // ============================================================

  double? userFrequency;

  final List<UserPitchPoint> userPitchHistory = [];

  // This keeps microphone pitch synchronized with the song.
  DateTime? singingStartClock;

  // ============================================================
  // TIMERS
  // ============================================================

  Timer? graphTimer;
  Timer? countdownTimer;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    audioPlayer.onPlayerComplete.listen((_) async {
      if (!mounted) return;

      await stopMicrophone();

      graphTimer?.cancel();

      setState(() {
        isPlaying = false;
        isSinging = false;
        currentTime = songDuration;
        userFrequency = null;
      });
    });
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    graphTimer?.cancel();
    countdownTimer?.cancel();

    micSubscription?.cancel();
    microphone.dispose();

    audioPlayer.dispose();

    super.dispose();
  }

  // ============================================================
  // PICK SONG
  // ============================================================

  Future<void> pickSong() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );

    if (result == null) return;

    final file = result.files.single;

    if (file.bytes == null) {
      setState(() {
        analysisStatus =
            'Could not read the selected audio file.';
      });
      return;
    }

    await audioPlayer.stop();
    await stopMicrophone();

    graphTimer?.cancel();
    countdownTimer?.cancel();

    setState(() {
      selectedSongName = file.name;
      selectedSongBytes = file.bytes;

      pitchCurve = [];
      userPitchHistory.clear();

      currentTime = 0.0;
      songDuration = 0.0;

      isPlaying = false;
      isSinging = false;
      isCountingDown = false;

      countdownValue = 0;
      userFrequency = null;

      analysisStatus = null;
    });

    await analyzeSong();
  }

  // ============================================================
  // ANALYZE SONG
  // ============================================================

  Future<void> analyzeSong() async {
    if (selectedSongBytes == null ||
        selectedSongName == null) {
      return;
    }

    setState(() {
      isAnalyzing = true;
      analysisStatus = 'Analyzing reference pitch...';
    });

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
          'http://localhost:8001/analyze',
        ),
      );

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          selectedSongBytes!,
          filename: selectedSongName!,
        ),
      );

      final streamedResponse = await request.send();

      final response =
          await http.Response.fromStream(
        streamedResponse,
      );

      if (response.statusCode != 200) {
        String message = 'Pitch analysis failed.';

        try {
          final errorData = jsonDecode(response.body);

          if (errorData['detail'] != null) {
            message = errorData['detail'].toString();
          }
        } catch (_) {}

        throw Exception(message);
      }

      final data = jsonDecode(response.body);

      final rawCurve =
          data['pitch_curve'] as List<dynamic>;

      final points = rawCurve.map((point) {
        return PitchPoint(
          time: (point['time'] as num).toDouble(),
          frequency:
              (point['frequency'] as num).toDouble(),
          voiced: point['voiced'] == true,
          confidence:
              point['confidence'] == null
                  ? 0.0
                  : (point['confidence'] as num).toDouble(),
        );
      }).toList();

      setState(() {
        pitchCurve = points;

        currentTime = 0.0;

        songDuration =
            data['duration'] == null
                ? (points.isEmpty ? 0.0 : points.last.time)
                : (data['duration'] as num).toDouble();

        isAnalyzing = false;

        analysisStatus = 'Reference melody ready';
      });
    } catch (error) {
      setState(() {
        isAnalyzing = false;
        analysisStatus = 'Error: $error';
      });
    }
  }

  // ============================================================
  // PLAY / PAUSE REFERENCE
  // ============================================================

  Future<void> togglePlayback() async {
    if (selectedSongBytes == null ||
        pitchCurve.isEmpty) {
      return;
    }

    if (isPlaying) {
      await audioPlayer.pause();

      stopGraphAnimation();

      setState(() {
        isPlaying = false;
      });

      return;
    }

    try {
      await audioPlayer.play(
        BytesSource(selectedSongBytes!),
      );

      if (currentTime > 0) {
        await audioPlayer.seek(
          Duration(
            milliseconds:
                (currentTime * 1000).round(),
          ),
        );
      }

      setState(() {
        isPlaying = true;
      });

      startGraphAnimation();
    } catch (error) {
      setState(() {
        analysisStatus =
            'Could not play the song: $error';
      });
    }
  }

  // ============================================================
  // SEEK
  // ============================================================

  Future<void> seekTo(double seconds) async {
    if (songDuration <= 0) return;

    final newTime = seconds.clamp(
      0.0,
      songDuration,
    );

    setState(() {
      currentTime = newTime;
    });

    if (selectedSongBytes != null) {
      await audioPlayer.seek(
        Duration(
          milliseconds:
              (newTime * 1000).round(),
        ),
      );
    }
  }

  // ============================================================
  // GRAPH ANIMATION
  // ============================================================

  void startGraphAnimation() {
    graphTimer?.cancel();

    if (pitchCurve.isEmpty) return;

    graphTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) async {
        if (!mounted ||
            pitchCurve.isEmpty ||
            !isPlaying) {
          return;
        }

        final position =
            await audioPlayer.getCurrentPosition();

        if (position == null) return;

        final seconds =
            position.inMilliseconds / 1000.0;

        if (seconds >= songDuration) {
          stopGraphAnimation();

          setState(() {
            currentTime = songDuration;
            isPlaying = false;
          });

          return;
        }

        setState(() {
          currentTime = seconds;
        });
      },
    );
  }

  void stopGraphAnimation() {
    graphTimer?.cancel();
    graphTimer = null;
  }

  // ============================================================
  // COUNTDOWN
  // ============================================================

  Future<void> startPracticeCountdown() async {
    if (pitchCurve.isEmpty ||
        selectedSongBytes == null) {
      return;
    }

    if (isPlaying) {
      await audioPlayer.pause();

      stopGraphAnimation();

      setState(() {
        isPlaying = false;
      });
    }

    await stopMicrophone();

    countdownTimer?.cancel();

    setState(() {
      isCountingDown = true;
      countdownValue = 3;

      userPitchHistory.clear();
      userFrequency = null;
    });

    countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (countdownValue > 1) {
          setState(() {
            countdownValue--;
          });

          return;
        }

        timer.cancel();

        // Remember exactly where the user chose to start.
        final startPosition = currentTime;

        setState(() {
          countdownValue = 0;
          isCountingDown = false;
          isSinging = true;

          analysisStatus = 'Listening...';
        });

        // Start the clock at the same moment as the microphone.
        singingStartClock = DateTime.now();

        await startMicrophone();

        await audioPlayer.play(
          BytesSource(selectedSongBytes!),
        );

        await audioPlayer.seek(
          Duration(
            milliseconds:
                (startPosition * 1000).round(),
          ),
        );

        setState(() {
          isPlaying = true;
          currentTime = startPosition;
        });

        startGraphAnimation();
      },
    );
  }

  // ============================================================
  // MICROPHONE
  // ============================================================

  Future<void> startMicrophone() async {
    final hasPermission =
        await microphone.hasPermission();

    if (!hasPermission) {
      if (!mounted) return;

      setState(() {
        isSinging = false;
        analysisStatus =
            'Microphone permission denied.';
      });

      return;
    }

    await microphone.stop();

    final stream =
        await microphone.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
    );

    await micSubscription?.cancel();

    micSubscription = stream.listen(
      detectLivePitch,
      onError: (error) {
        if (!mounted) return;

        setState(() {
          analysisStatus =
              'Microphone error: $error';
        });
      },
    );
  }

  // ============================================================
  // STOP MICROPHONE
  // ============================================================

  Future<void> stopMicrophone() async {
    await micSubscription?.cancel();

    micSubscription = null;

    try {
      await microphone.stop();
    } catch (_) {}
  }

  // ============================================================
  // STOP SINGING
  // ============================================================

  Future<void> stopSinging() async {
    countdownTimer?.cancel();

    await stopMicrophone();

    if (isPlaying) {
      await audioPlayer.pause();
    }

    stopGraphAnimation();

    if (!mounted) return;

    setState(() {
      isSinging = false;
      isPlaying = false;
      userFrequency = null;

      analysisStatus = 'Practice stopped';
    });
  }

  // ============================================================
  // LIVE PITCH DETECTION
  // ============================================================

  void detectLivePitch(Uint8List bytes) {
    if (!isSinging || bytes.length < 2048) {
      return;
    }

    final samples = <double>[];

    for (
      int i = 0;
      i + 1 < bytes.length;
      i += 2
    ) {
      int value =
          bytes[i] |
          (bytes[i + 1] << 8);

      if (value >= 32768) {
        value -= 65536;
      }

      samples.add(
        value / 32768.0,
      );
    }

    if (samples.length < 1024) {
      return;
    }

    final frequency = detectFrequency(
      samples,
      44100,
    );

    if (frequency == null) {
      return;
    }

    if (!mounted ||
        singingStartClock == null) {
      return;
    }

    // Time since the microphone started.
    final elapsed =
        DateTime.now()
            .difference(
              singingStartClock!,
            )
            .inMilliseconds /
        1000.0;

    // Current song position + microphone elapsed time.
    final practiceTime =
        currentTime + elapsed;

    if (practiceTime > songDuration) {
      return;
    }

    setState(() {
      userFrequency = frequency;

      userPitchHistory.add(
        UserPitchPoint(
          time: practiceTime,
          frequency: frequency,
        ),
      );

      if (userPitchHistory.length > 500) {
        userPitchHistory.removeAt(0);
      }
    });
  }

  // ============================================================
  // SIMPLE AUTOCORRELATION PITCH DETECTOR
  // ============================================================

  double? detectFrequency(
    List<double> samples,
    int sampleRate,
  ) {
    double rms = 0.0;

    for (final sample in samples) {
      rms += sample * sample;
    }

    rms = math.sqrt(
      rms / samples.length,
    );

    if (rms < 0.015) {
      return null;
    }

    const minFrequency = 80.0;
    const maxFrequency = 1000.0;

    final minLag =
        (sampleRate / maxFrequency).round();

    final maxLag =
        (sampleRate / minFrequency).round();

    double bestCorrelation = 0.0;
    int bestLag = 0;

    for (
      int lag = minLag;
      lag <= maxLag;
      lag++
    ) {
      double correlation = 0.0;

      final limit =
          samples.length - lag;

      for (
        int i = 0;
        i < limit;
        i++
      ) {
        correlation +=
            samples[i] *
            samples[i + lag];
      }

      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestLag = lag;
      }
    }

    if (bestLag == 0) {
      return null;
    }

    final frequency =
        sampleRate / bestLag;

    if (frequency < minFrequency ||
        frequency > maxFrequency) {
      return null;
    }

    return frequency;
  }

  // ============================================================
  // FORMAT TIME
  // ============================================================

  String formatTime(double seconds) {
    final totalSeconds = seconds.floor();

    final minutes = totalSeconds ~/ 60;
    final secs = totalSeconds % 60;

    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          const Color(0xFF0B0C0F),

      appBar: AppBar(
        backgroundColor:
            const Color(0xFF0B0C0F),
        elevation: 0,
        title: const Text(
          'MUSIQ — LEARNING',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      ),

      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'Vocal Learning',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'Upload a song and practice your vocals.',
                style: TextStyle(
                  color:
                      Colors.white.withValues(
                    alpha: 0.65,
                  ),
                  fontSize: 16,
                ),
              ),

              const SizedBox(height: 32),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed:
                      isAnalyzing ? null : pickSong,
                  icon: const Icon(
                    Icons.upload_file_rounded,
                  ),
                  label: Text(
                    isAnalyzing
                        ? 'Analyzing...'
                        : 'Upload Song',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style:
                      ElevatedButton.styleFrom(
                    backgroundColor:
                        const Color(0xFFA855F7),
                    foregroundColor:
                        Colors.white,
                    disabledBackgroundColor:
                        const Color(0xFFA855F7)
                            .withValues(
                      alpha: 0.4,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              if (selectedSongName != null)
                _buildSongCard(),

              const SizedBox(height: 24),

              _buildPitchGraph(),

              const SizedBox(height: 24),

              if (pitchCurve.isNotEmpty)
                _buildPracticeSection(),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // SONG CARD
  // ============================================================

  Widget _buildSongCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF171922),
        borderRadius:
            BorderRadius.circular(20),
        border: Border.all(
          color:
              const Color(0xFFA855F7)
                  .withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color:
                  const Color(0xFFA855F7)
                      .withValues(alpha: 0.15),
              borderRadius:
                  BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: Color(0xFFA855F7),
              size: 26,
            ),
          ),

          const SizedBox(width: 16),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                const Text(
                  'Learning Song',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 5),

                Text(
                  selectedSongName!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight:
                        FontWeight.w600,
                  ),
                  overflow:
                      TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // PITCH GRAPH
  // ============================================================

  Widget _buildPitchGraph() {
    return Container(
      width: double.infinity,
      height: 440,
      decoration: BoxDecoration(
        color: const Color(0xFF171922),
        borderRadius:
            BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Reference Pitch',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),

                if (pitchCurve.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color:
                          const Color(0xFFA855F7)
                              .withValues(
                        alpha: 0.12,
                      ),
                      borderRadius:
                          BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'READY',
                      style: TextStyle(
                        color:
                            Color(0xFFA855F7),
                        fontSize: 11,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 4),

            Text(
              analysisStatus ??
                  'Upload a song to see its reference melody.',
              style: TextStyle(
                color:
                    Colors.white.withValues(
                  alpha: 0.55,
                ),
                fontSize: 13,
              ),
            ),

            const SizedBox(height: 16),

            Expanded(
              child: Stack(
                children: [
                  isAnalyzing
                      ? const Center(
                          child:
                              CircularProgressIndicator(
                            color:
                                Color(0xFFA855F7),
                          ),
                        )
                      : pitchCurve.isEmpty
                          ? Center(
                              child: Icon(
                                Icons
                                    .show_chart_rounded,
                                size: 70,
                                color:
                                    const Color(
                                  0xFFA855F7,
                                ).withValues(
                                  alpha: 0.35,
                                ),
                              ),
                            )
                          : ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(
                                12,
                              ),
                              child: CustomPaint(
                                painter:
                                    PitchGraphPainter(
                                  points:
                                      pitchCurve,
                                  userPoints:
                                      userPitchHistory,
                                  currentTime:
                                      currentTime,
                                  visibleWindow:
                                      visibleWindow,
                                ),
                                size: Size.infinite,
                              ),
                            ),

                  if (isCountingDown)
                    Center(
                      child:
                          AnimatedSwitcher(
                        duration:
                            const Duration(
                          milliseconds: 250,
                        ),
                        child: Text(
                          '$countdownValue',
                          key: ValueKey(
                            countdownValue,
                          ),
                          style:
                              const TextStyle(
                            color: Colors.white,
                            fontSize: 80,
                            fontWeight:
                                FontWeight.w900,
                            shadows: [
                              Shadow(
                                blurRadius: 25,
                                color:
                                    Color(
                                  0xFFA855F7,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  if (isSinging &&
                      userFrequency != null)
                    Positioned(
                      right: 12,
                      top: 12,
                      child: Container(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration:
                            BoxDecoration(
                          color:
                              const Color(
                            0xFF171922,
                          ).withValues(
                            alpha: 0.9,
                          ),
                          borderRadius:
                              BorderRadius.circular(
                            12,
                          ),
                        ),
                        child: Text(
                          '${userFrequency!.toStringAsFixed(1)} Hz',
                          style:
                              const TextStyle(
                            color: Colors.white,
                            fontWeight:
                                FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            if (pitchCurve.isNotEmpty)
              Row(
                children: [
                  Text(
                    formatTime(currentTime),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),

                  Expanded(
                    child: Slider(
                      value:
                          currentTime.clamp(
                        0.0,
                        songDuration > 0
                            ? songDuration
                            : 1.0,
                      ),
                      min: 0,
                      max:
                          songDuration > 0
                              ? songDuration
                              : 1.0,
                      activeColor:
                          const Color(0xFFA855F7),
                      inactiveColor:
                          Colors.white12,
                      onChanged: (value) {
                        setState(() {
                          currentTime = value;
                        });
                      },
                      onChangeEnd: (value) {
                        seekTo(value);
                      },
                    ),
                  ),

                  Text(
                    formatTime(songDuration),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // PRACTICE SECTION
  // ============================================================

  Widget _buildPracticeSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF171922),
        borderRadius:
            BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          const Text(
            'Practice',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            'Choose any point in the song, listen to the reference, then sing along.',
            style: TextStyle(
              color:
                  Colors.white.withValues(
                alpha: 0.55,
              ),
              fontSize: 14,
            ),
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed:
                  isSinging ? null : togglePlayback,
              icon: Icon(
                isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                isPlaying
                    ? 'Pause Reference'
                    : 'Play Reference',
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    const Color(0xFF2A2D38),
                foregroundColor:
                    Colors.white,
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(14),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed:
                  isCountingDown
                      ? null
                      : isSinging
                          ? stopSinging
                          : startPracticeCountdown,
              icon: Icon(
                isSinging
                    ? Icons.stop_rounded
                    : Icons.mic_rounded,
              ),
              label: Text(
                isCountingDown
                    ? 'Get Ready...'
                    : isSinging
                        ? 'Stop Singing'
                        : 'Start Singing',
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor:
                    const Color(0xFFA855F7),
                foregroundColor:
                    Colors.white,
                disabledBackgroundColor:
                    const Color(0xFFA855F7)
                        .withValues(
                  alpha: 0.4,
                ),
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================================================================
// REFERENCE PITCH POINT
// ==================================================================

class PitchPoint {
  final double time;
  final double frequency;
  final bool voiced;
  final double confidence;

  PitchPoint({
    required this.time,
    required this.frequency,
    required this.voiced,
    required this.confidence,
  });
}

// ==================================================================
// USER PITCH POINT
// ==================================================================

class UserPitchPoint {
  final double time;
  final double frequency;

  UserPitchPoint({
    required this.time,
    required this.frequency,
  });
}

// ==================================================================
// PITCH GRAPH
// ==================================================================

class PitchGraphPainter extends CustomPainter {
  final List<PitchPoint> points;
  final List<UserPitchPoint> userPoints;

  final double currentTime;
  final double visibleWindow;

  PitchGraphPainter({
    required this.points,
    required this.userPoints,
    required this.currentTime,
    required this.visibleWindow,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    if (points.isEmpty) return;

    final backgroundPaint = Paint()
      ..color = const Color(0xFF0B0C0F);

    canvas.drawRect(
      Offset.zero & size,
      backgroundPaint,
    );

    // ==========================================================
    // MOVING WINDOW
    //
    // The playhead stays FIXED in the center.
    // The melody moves underneath it.
    // ==========================================================

    final windowStart =
        currentTime -
        visibleWindow / 2;

    final windowEnd =
        currentTime +
        visibleWindow / 2;

    // ==========================================================
    // VALID REFERENCE POINTS
    // ==========================================================

    final validPoints =
        points.where(
      (point) =>
          point.time >= windowStart &&
          point.time <= windowEnd &&
          point.voiced &&
          point.frequency > 0 &&
          point.confidence >= 0.45,
    ).toList();

    if (validPoints.isEmpty) {
      _drawPlayhead(canvas, size);
      return;
    }

    // ==========================================================
    // FREQUENCY RANGE
    // ==========================================================

    double minFrequency =
        validPoints
            .map(
              (point) => point.frequency,
            )
            .reduce(
              (a, b) => a < b ? a : b,
            );

    double maxFrequency =
        validPoints
            .map(
              (point) => point.frequency,
            )
            .reduce(
              (a, b) => a > b ? a : b,
            );

    // Include user's pitch.
    for (final point in userPoints) {
      if (point.time >= windowStart &&
          point.time <= windowEnd) {
        minFrequency = math.min(
          minFrequency,
          point.frequency,
        );

        maxFrequency = math.max(
          maxFrequency,
          point.frequency,
        );
      }
    }

    final frequencyPadding =
        (maxFrequency - minFrequency) *
                0.08 +
            5;

    minFrequency -= frequencyPadding;
    maxFrequency += frequencyPadding;

    final padding = 12.0;

    final graphWidth =
        size.width - padding * 2;

    final graphHeight =
        size.height - padding * 2;

    final frequencyRange =
        math.max(
      maxFrequency - minFrequency,
      1,
    );

    // ==========================================================
    // GRID
    // ==========================================================

    final gridPaint = Paint()
      ..color =
          Colors.white.withValues(
        alpha: 0.06,
      )
      ..strokeWidth = 1;

    for (int i = 1; i < 5; i++) {
      final y =
          padding +
          graphHeight * i / 5;

      canvas.drawLine(
        Offset(
          padding,
          y,
        ),
        Offset(
          size.width - padding,
          y,
        ),
        gridPaint,
      );
    }

    // ==========================================================
    // REFERENCE MELODY
    // ==========================================================

    final referencePaint = Paint()
      ..color = const Color(0xFFA855F7)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path? referencePath;
    PitchPoint? previousReference;

    for (final point in points) {
      if (point.time < windowStart ||
          point.time > windowEnd) {
        continue;
      }

      final valid =
          point.voiced &&
          point.frequency > 0 &&
          point.confidence >= 0.45;

      if (!valid) {
        if (referencePath != null) {
          canvas.drawPath(
            referencePath,
            referencePaint,
          );
        }

        referencePath = null;
        previousReference = null;

        continue;
      }

      final relativeTime =
          point.time - windowStart;

      final x =
          padding +
          (relativeTime / visibleWindow) *
              graphWidth;

      final normalized =
          (point.frequency -
                  minFrequency) /
              frequencyRange;

      final y =
          padding +
          graphHeight -
          normalized * graphHeight;

      final gapIsTooLarge =
          previousReference != null &&
          (point.time -
                  previousReference!.time) >
              0.15;

      if (referencePath == null ||
          gapIsTooLarge) {
        if (referencePath != null) {
          canvas.drawPath(
            referencePath,
            referencePaint,
          );
        }

        referencePath = Path();

        referencePath.moveTo(
          x,
          y,
        );
      } else {
        referencePath.lineTo(
          x,
          y,
        );
      }

      previousReference = point;
    }

    if (referencePath != null) {
      canvas.drawPath(
        referencePath,
        referencePaint,
      );
    }

    // ==========================================================
    // USER LIVE PITCH
    // ==========================================================

    final userPaint = Paint()
      ..color = const Color(0xFFFF40DA)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path? userPath;
    UserPitchPoint? previousUser;

    for (final point in userPoints) {
      if (point.time < windowStart ||
          point.time > windowEnd) {
        continue;
      }

      final relativeTime =
          point.time - windowStart;

      final x =
          padding +
          (relativeTime / visibleWindow) *
              graphWidth;

      final normalized =
          (point.frequency -
                  minFrequency) /
              frequencyRange;

      final y =
          padding +
          graphHeight -
          normalized * graphHeight;

      final gapIsTooLarge =
          previousUser != null &&
          (point.time -
                  previousUser!.time) >
              0.3;

      if (userPath == null ||
          gapIsTooLarge) {
        if (userPath != null) {
          canvas.drawPath(
            userPath,
            userPaint,
          );
        }

        userPath = Path();

        userPath.moveTo(
          x,
          y,
        );
      } else {
        userPath.lineTo(
          x,
          y,
        );
      }

      previousUser = point;
    }

    if (userPath != null) {
      canvas.drawPath(
        userPath,
        userPaint,
      );
    }

    // ==========================================================
    // FIXED PLAYHEAD
    // ==========================================================

    _drawPlayhead(
      canvas,
      size,
    );

    // ==========================================================
    // CURRENT USER PITCH DOT
    // ==========================================================

    if (userPoints.isNotEmpty) {
      UserPitchPoint? closest;

      double smallestDifference =
          double.infinity;

      for (final point in userPoints) {
        final difference =
            (point.time - currentTime).abs();

        if (difference < smallestDifference) {
          smallestDifference = difference;
          closest = point;
        }
      }

      if (closest != null &&
          smallestDifference < 0.25) {
        final relativeTime =
            closest.time - windowStart;

        final x =
            padding +
            (relativeTime / visibleWindow) *
                graphWidth;

        final normalized =
            (closest.frequency -
                    minFrequency) /
                frequencyRange;

        final y =
            padding +
            graphHeight -
            normalized * graphHeight;

        final dotPaint = Paint()
          ..color = Colors.white;

        canvas.drawCircle(
          Offset(x, y),
          6,
          dotPaint,
        );
      }
    }
  }

  // ============================================================
  // FIXED PLAYHEAD
  // ============================================================

  void _drawPlayhead(
    Canvas canvas,
    Size size,
  ) {
    final playheadX =
        size.width / 2;

    final playheadPaint = Paint()
      ..color =
          Colors.white.withValues(
        alpha: 0.85,
      )
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(
        playheadX,
        0,
      ),
      Offset(
        playheadX,
        size.height,
      ),
      playheadPaint,
    );

    final trianglePath = Path();

    trianglePath.moveTo(
      playheadX - 12,
      7,
    );

    trianglePath.lineTo(
      playheadX + 12,
      7,
    );

    trianglePath.lineTo(
      playheadX,
      21,
    );

    trianglePath.close();

    final trianglePaint = Paint()
      ..color = Colors.white;

    canvas.drawPath(
      trianglePath,
      trianglePaint,
    );
  }

  @override
  bool shouldRepaint(
    covariant PitchGraphPainter oldDelegate,
  ) {
    return oldDelegate.points != points ||
        oldDelegate.userPoints != userPoints ||
        oldDelegate.currentTime != currentTime ||
        oldDelegate.visibleWindow !=
            visibleWindow;
  }
}