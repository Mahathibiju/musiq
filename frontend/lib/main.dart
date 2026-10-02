import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MusiqApp());
}

// ============================================================
// MUSIQ APP
// ============================================================

class MusiqApp extends StatelessWidget {
  const MusiqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Isai',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080909),
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF0442E),
          brightness: Brightness.dark,
        ),
      ),
      home: const SoundMixerPage(),
    );
  }
}

// ============================================================
// COLORS
// ============================================================

const Color kBackground = Color(0xFF080909);
const Color kPanel = Color(0xFF111212);
const Color kPanelLight = Color(0xFF171818);

const Color kRed = Color(0xFFF0442E);
const Color kDarkRed = Color(0xFFA52D22);

const Color kCream = Color(0xFFF1E4C8);
const Color kMuted = Color(0xFF9D9688);

const Color kBlack = Color(0xFF050505);

// ============================================================
// STEM DATA
// ============================================================

class StemData {
  final String name;
  final IconData icon;
  final Color color;
  final AudioPlayer player;

  double volume;
  bool muted;

  StemData({
    required this.name,
    required this.icon,
    required this.color,
    required this.player,
    this.volume = 1.0,
    this.muted = false,
  });
}

// ============================================================
// MAIN PAGE
// ============================================================

class SoundMixerPage extends StatefulWidget {
  const SoundMixerPage({super.key});

  @override
  State<SoundMixerPage> createState() => _SoundMixerPageState();
}

class _SoundMixerPageState extends State<SoundMixerPage> {
  // ==========================================================
  // BACKEND
  // ==========================================================

  static const String backendUrl = 'http://127.0.0.1:8000';

  // ==========================================================
  // AUDIO PLAYERS
  // ==========================================================

  final AudioPlayer vocalsPlayer = AudioPlayer();
  final AudioPlayer drumsPlayer = AudioPlayer();
  final AudioPlayer bassPlayer = AudioPlayer();
  final AudioPlayer otherPlayer = AudioPlayer();

  late final List<StemData> stems;

  // ==========================================================
  // STREAMS
  // ==========================================================

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;

  // ==========================================================
  // SONG STATE
  // ==========================================================

  String? selectedFileName;
  String? jobId;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  // ==========================================================
  // UI STATE
  // ==========================================================

  bool isPlaying = false;
  bool isLoading = false;
  bool stemsReady = false;
  bool removeVocals = false;

  // ==========================================================
  // MIX STATE
  // ==========================================================

  double masterVolume = 1.0;

  // Transpose:
  // -12 to +12 semitones
  double transpose = 0.0;

  // Tempo:
  // -100 = slowest
  // 0 = original
  // +100 = fastest
  double tempo = 0.0;

  String statusMessage = 'Upload a song to begin';

  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();

    stems = [
      StemData(
        name: 'VOCALS',
        icon: Icons.mic_none_rounded,
        color: kRed,
        player: vocalsPlayer,
      ),
      StemData(
        name: 'DRUMS',
        icon: Icons.album_rounded,
        color: kCream,
        player: drumsPlayer,
      ),
      StemData(
        name: 'BASS',
        icon: Icons.graphic_eq_rounded,
        color: kRed,
        player: bassPlayer,
      ),
      StemData(
        name: 'OTHER',
        icon: Icons.piano_rounded,
        color: kCream,
        player: otherPlayer,
      ),
    ];

    // ========================================================
    // PLAYBACK POSITION
    // ========================================================

    _positionSubscription =
        vocalsPlayer.onPositionChanged.listen((newPosition) {
      if (!mounted) return;

      setState(() {
        position = newPosition;
      });
    });

    // ========================================================
    // SONG DURATION
    // ========================================================

    _durationSubscription =
        vocalsPlayer.onDurationChanged.listen((newDuration) {
      if (!mounted) return;

      setState(() {
        duration = newDuration;
      });
    });
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();

    vocalsPlayer.dispose();
    drumsPlayer.dispose();
    bassPlayer.dispose();
    otherPlayer.dispose();

    super.dispose();
  }

  // ==========================================================
  // UPLOAD + SEPARATE
  // ==========================================================

  Future<void> pickSong() async {
    if (isLoading) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp3',
          'wav',
          'm4a',
          'flac',
          'ogg',
        ],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;

      if (file.bytes == null) {
        setState(() {
          statusMessage = 'Could not read the selected file.';
        });

        return;
      }

      setState(() {
        isLoading = true;
        stemsReady = false;
        isPlaying = false;

        position = Duration.zero;
        duration = Duration.zero;

        selectedFileName = file.name;

        transpose = 0.0;
        tempo = 0.0;

        statusMessage = 'Uploading song...';
      });

      await stopAll();

      // ======================================================
      // SEND SONG TO BACKEND
      // ======================================================

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$backendUrl/separate'),
      );

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ),
      );

      final streamedResponse = await request.send();

      final response = await http.Response.fromStream(
        streamedResponse,
      );

      if (response.statusCode != 200) {
        String errorMessage =
            'Backend error (${response.statusCode})';

        try {
          final errorJson = jsonDecode(response.body);

          if (errorJson is Map &&
              errorJson['detail'] != null) {
            errorMessage = errorJson['detail'].toString();
          }
        } catch (_) {}

        throw Exception(errorMessage);
      }

      final data = jsonDecode(response.body);

      final Map<String, dynamic> stemUrls =
          Map<String, dynamic>.from(data['stems']);

      jobId = data['job_id']?.toString();

      // ======================================================
      // VERIFY FOUR STEMS
      // ======================================================

      for (final name in [
        'vocals',
        'drums',
        'bass',
        'other',
      ]) {
        if (stemUrls[name] == null) {
          throw Exception(
            'Backend did not return $name stem.',
          );
        }
      }

      setState(() {
        statusMessage = 'Loading 4 separated stems...';
      });

      // ======================================================
      // LOAD FOUR STEMS
      // ======================================================

      await loadStem(
        vocalsPlayer,
        stemUrls['vocals'].toString(),
      );

      await loadStem(
        drumsPlayer,
        stemUrls['drums'].toString(),
      );

      await loadStem(
        bassPlayer,
        stemUrls['bass'].toString(),
      );

      await loadStem(
        otherPlayer,
        stemUrls['other'].toString(),
      );

      // ======================================================
      // RESET MIX SETTINGS
      // ======================================================

      for (final stem in stems) {
        stem.volume = 1.0;
        stem.muted = false;

        await stem.player.setVolume(
          masterVolume,
        );
      }

      setState(() {
        stemsReady = true;
        isLoading = false;

        statusMessage = '4 stems ready';
      });
    } catch (e) {
      await stopAll();

      if (!mounted) return;

      setState(() {
        isLoading = false;
        stemsReady = false;
        isPlaying = false;

        statusMessage = 'Error: $e';
      });
    }
  }

  // ==========================================================
  // LOAD AUDIO STEM
  // ==========================================================

  Future<void> loadStem(
    AudioPlayer player,
    String relativeUrl,
  ) async {
    final fullUrl = '$backendUrl$relativeUrl';

    await player.setSourceUrl(fullUrl);
  }

  // ==========================================================
  // APPLY TRANSPOSE
  // ==========================================================

  Future<void> applyTranspose(
    double semitones,
  ) async {
    if (!stemsReady || jobId == null) {
      return;
    }

    final int requestedSemitones = semitones.round();

    try {
      setState(() {
        isLoading = true;
        isPlaying = false;

        statusMessage = requestedSemitones == 0
            ? 'Restoring original pitch...'
            : 'Transposing to '
                '${requestedSemitones > 0 ? '+' : ''}'
                '$requestedSemitones semitones...';
      });

      await stopAll();

      // ======================================================
      // CALL BACKEND
      // ======================================================

      final response = await http.post(
        Uri.parse('$backendUrl/transpose'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'job_id': jobId,
          'semitones': requestedSemitones,
        }),
      );

      if (response.statusCode != 200) {
        String message = 'Transpose failed';

        try {
          final error = jsonDecode(response.body);

          if (error is Map &&
              error['detail'] != null) {
            message = error['detail'].toString();
          }
        } catch (_) {}

        throw Exception(message);
      }

      final data = jsonDecode(response.body);

      final Map<String, dynamic> stemUrls =
          Map<String, dynamic>.from(data['stems']);

      for (final name in [
        'vocals',
        'drums',
        'bass',
        'other',
      ]) {
        if (stemUrls[name] == null) {
          throw Exception(
            'Transpose response is missing $name.',
          );
        }
      }

      // ======================================================
      // LOAD TRANSPOSED STEMS
      // ======================================================

      await loadStem(
        vocalsPlayer,
        stemUrls['vocals'].toString(),
      );

      await loadStem(
        drumsPlayer,
        stemUrls['drums'].toString(),
      );

      await loadStem(
        bassPlayer,
        stemUrls['bass'].toString(),
      );

      await loadStem(
        otherPlayer,
        stemUrls['other'].toString(),
      );

      // ======================================================
      // RESTORE VOLUMES
      // ======================================================

      for (final stem in stems) {
        await stem.player.setVolume(
          stem.muted
              ? 0.0
              : stem.volume * masterVolume,
        );
      }

      if (!mounted) return;

      setState(() {
        transpose = requestedSemitones.toDouble();

        isLoading = false;
        isPlaying = false;

        position = Duration.zero;

        statusMessage = requestedSemitones == 0
            ? 'Original pitch restored'
            : 'Transpose '
                '${requestedSemitones > 0 ? '+' : ''}'
                '$requestedSemitones applied';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
        isPlaying = false;

        statusMessage = 'Transpose error: $e';
      });
    }
  }

  // ==========================================================
  // APPLY TEMPO
  // ==========================================================

  Future<void> applyTempo(
    double tempoValue,
  ) async {
    if (!stemsReady || jobId == null) {
      return;
    }

    final int requestedTempo = tempoValue.round();

    try {
      setState(() {
        isLoading = true;
        isPlaying = false;

        statusMessage = requestedTempo == 0
            ? 'Restoring original tempo...'
            : 'Changing tempo to '
                '${requestedTempo > 0 ? '+' : ''}'
                '$requestedTempo...';
      });

      await stopAll();

      // ======================================================
      // CALL BACKEND
      // ======================================================

      final response = await http.post(
        Uri.parse('$backendUrl/tempo'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'job_id': jobId,
          'tempo_percent': requestedTempo,
        }),
      );

      if (response.statusCode != 200) {
        String message = 'Tempo change failed';

        try {
          final error = jsonDecode(response.body);

          if (error is Map &&
              error['detail'] != null) {
            message = error['detail'].toString();
          }
        } catch (_) {}

        throw Exception(message);
      }

      final data = jsonDecode(response.body);

      final Map<String, dynamic> stemUrls =
          Map<String, dynamic>.from(data['stems']);

      // ======================================================
      // VERIFY
      // ======================================================

      for (final name in [
        'vocals',
        'drums',
        'bass',
        'other',
      ]) {
        if (stemUrls[name] == null) {
          throw Exception(
            'Tempo response is missing $name.',
          );
        }
      }

      // ======================================================
      // LOAD TEMPO STEMS
      // ======================================================

      await loadStem(
        vocalsPlayer,
        stemUrls['vocals'].toString(),
      );

      await loadStem(
        drumsPlayer,
        stemUrls['drums'].toString(),
      );

      await loadStem(
        bassPlayer,
        stemUrls['bass'].toString(),
      );

      await loadStem(
        otherPlayer,
        stemUrls['other'].toString(),
      );

      // ======================================================
      // RESTORE VOLUMES
      // ======================================================

      for (final stem in stems) {
        await stem.player.setVolume(
          stem.muted
              ? 0.0
              : stem.volume * masterVolume,
        );
      }

      if (!mounted) return;

      setState(() {
        tempo = requestedTempo.toDouble();

        isLoading = false;
        isPlaying = false;

        position = Duration.zero;

        statusMessage = requestedTempo == 0
            ? 'Original tempo restored'
            : 'Tempo '
                '${requestedTempo > 0 ? '+' : ''}'
                '$requestedTempo applied';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
        isPlaying = false;

        statusMessage = 'Tempo error: $e';
      });
    }
  }

  // ==========================================================
  // PLAY ALL
  // ==========================================================

  Future<void> playAll() async {
    if (!stemsReady) return;

    try {
      if (isPlaying) {
        await pauseAll();
        return;
      }

      setState(() {
        statusMessage = 'Playing...';
      });

      await Future.wait([
        vocalsPlayer.resume(),
        drumsPlayer.resume(),
        bassPlayer.resume(),
        otherPlayer.resume(),
      ]);

      if (!mounted) return;

      setState(() {
        isPlaying = true;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        statusMessage = 'Playback error: $e';
        isPlaying = false;
      });
    }
  }

  // ==========================================================
  // PAUSE
  // ==========================================================

  Future<void> pauseAll() async {
    await Future.wait([
      vocalsPlayer.pause(),
      drumsPlayer.pause(),
      bassPlayer.pause(),
      otherPlayer.pause(),
    ]);

    if (!mounted) return;

    setState(() {
      isPlaying = false;
      statusMessage = 'Paused';
    });
  }

  // ==========================================================
  // STOP
  // ==========================================================

  Future<void> stopAll() async {
    await Future.wait([
      vocalsPlayer.stop(),
      drumsPlayer.stop(),
      bassPlayer.stop(),
      otherPlayer.stop(),
    ]);

    if (!mounted) return;

    setState(() {
      isPlaying = false;
      position = Duration.zero;
    });
  }

  // ==========================================================
  // SEEK ALL
  // ==========================================================

  Future<void> seekAll(
    Duration newPosition,
  ) async {
    if (!stemsReady) return;

    await Future.wait([
      vocalsPlayer.seek(newPosition),
      drumsPlayer.seek(newPosition),
      bassPlayer.seek(newPosition),
      otherPlayer.seek(newPosition),
    ]);

    if (!mounted) return;

    setState(() {
      position = newPosition;
    });
  }

  // ==========================================================
  // STEM VOLUME
  // ==========================================================

  Future<void> changeStemVolume(
    StemData stem,
    double value,
  ) async {
    setState(() {
      stem.volume = value;
    });

    await stem.player.setVolume(
      stem.muted
          ? 0.0
          : value * masterVolume,
    );
  }

  // ==========================================================
  // MUTE
  // ==========================================================

  Future<void> toggleMute(
    StemData stem,
  ) async {
    setState(() {
      stem.muted = !stem.muted;
    });

    await stem.player.setVolume(
      stem.muted
          ? 0.0
          : stem.volume * masterVolume,
    );
  }

  // ==========================================================
  // MASTER VOLUME
  // ==========================================================

  Future<void> changeMasterVolume(
    double value,
  ) async {
    setState(() {
      masterVolume = value;
    });

    for (final stem in stems) {
      await stem.player.setVolume(
        stem.muted
            ? 0.0
            : stem.volume * masterVolume,
      );
    }
  }

  // ==========================================================
  // REMOVE VOCALS
  // ==========================================================

  Future<void> toggleRemoveVocals() async {
    setState(() {
      removeVocals = !removeVocals;
    });

    final vocals = stems.first;

    await vocals.player.setVolume(
      removeVocals
          ? 0.0
          : vocals.volume * masterVolume,
    );
  }

  // ==========================================================
  // FORMAT TIME
  // ==========================================================

  String formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  // ==========================================================
  // SAVE FINAL MIX
  // ==========================================================

  Future<void> saveFinalMix() async {
    if (!stemsReady || jobId == null) {
      return;
    }

    try {
      setState(() {
        statusMessage = 'Saving final mix...';
      });

      final stemSettings = <String, dynamic>{};

      for (final stem in stems) {
        final key = stem.name.toLowerCase();

        stemSettings[key] = {
          'volume': stem.volume,
          'muted': stem.muted,
        };
      }

      // Remove vocals overrides vocal settings.
      if (removeVocals) {
        stemSettings['vocals'] = {
          'volume': 0.0,
          'muted': true,
        };
      }

      // ======================================================
      // EXPORT REQUEST
      // ======================================================

      final response = await http.post(
        Uri.parse('$backendUrl/export'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'job_id': jobId,
          'master_volume': masterVolume,
          'semitones': transpose.round(),
          'stems': stemSettings,
        }),
      );

      if (response.statusCode != 200) {
        String message = 'Export failed';

        try {
          final error = jsonDecode(response.body);

          if (error is Map &&
              error['detail'] != null) {
            message = error['detail'].toString();
          }
        } catch (_) {}

        throw Exception(message);
      }

      final data = jsonDecode(response.body);

      final downloadUrl =
          '$backendUrl${data['download_url']}';

      // ======================================================
      // BROWSER DOWNLOAD
      // ======================================================

      final anchor = html.AnchorElement(
        href: downloadUrl,
      )
        ..setAttribute(
          'download',
          'Musiq_Final.mp3',
        )
        ..style.display = 'none';

      html.document.body?.children.add(anchor);

      anchor.click();
      anchor.remove();

      if (!mounted) return;

      setState(() {
        statusMessage = 'Final mix saved!';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Musiq_Final.mp3 downloaded successfully',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        statusMessage = 'Save failed';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Save failed: $e',
          ),
        ),
      );
    }
  }

  // ==========================================================
  // SMALL DIVIDER
  // ==========================================================

  Widget buildRedLine() {
    return Container(
      height: 2,
      color: kRed,
    );
  }

  // ==========================================================
  // HEADER
  // ==========================================================

  Widget buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        18,
        20,
        18,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // --------------------------------------------------
          // LOGO
          // --------------------------------------------------

          Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: const [
              Text(
                'இசை',
                style: TextStyle(
                  fontSize: 42,
                  height: 0.9,
                  fontWeight: FontWeight.w900,
                  color: kCream,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'I S A I',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 5,
                  color: kMuted,
                ),
              ),
            ],
          ),

          const SizedBox(width: 12),

          // --------------------------------------------------
          // SUNBURST
          // --------------------------------------------------

          Container(
            width: 54,
            height: 54,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: kRed,
            ),
            child: const Icon(
              Icons.wb_sunny_outlined,
              color: kBlack,
              size: 34,
            ),
          ),

          const Spacer(),

          // --------------------------------------------------
          // READY
          // --------------------------------------------------

          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: Colors.white24,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: kRed,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  stemsReady ? 'READY' : 'OFFLINE',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: kCream,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // UPLOAD PANEL
  // ==========================================================

  Widget buildUploadPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: 16,
      ),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: kRed.withOpacity(0.55),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: kRed,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.music_note_rounded,
              color: kBlack,
              size: 25,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  selectedFileName ??
                      'NO SONG SELECTED',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                    color: kCream,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  statusMessage,
                  maxLines: 2,
                  overflow:
                      TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          GestureDetector(
            onTap: isLoading
                ? null
                : pickSong,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              decoration: BoxDecoration(
                color: kRed,
                borderRadius:
                    BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  if (isLoading)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child:
                          CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kBlack,
                      ),
                    )
                  else
                    const Icon(
                      Icons.upload_rounded,
                      color: kBlack,
                      size: 17,
                    ),

                  const SizedBox(width: 6),

                  Text(
                    isLoading
                        ? 'WAIT'
                        : 'UPLOAD',
                    style: const TextStyle(
                      color: kBlack,
                      fontSize: 10,
                      fontWeight:
                          FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // VINYL RECORD
  // ==========================================================

  Widget buildVinylRecord() {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF111111),
        border: Border.all(
          color: kCream.withOpacity(0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.8),
            blurRadius: 30,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Vinyl grooves
          for (int i = 0; i < 7; i++)
            Container(
              width: 188.0 - (i * 18),
              height: 188.0 - (i * 18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white
                      .withOpacity(0.045),
                  width: 1,
                ),
              ),
            ),

          // Red label
          Container(
            width: 70,
            height: 70,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: kRed,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: kBlack,
              size: 38,
            ),
          ),

          // Centre
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: kCream,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // PLAYER
  // ==========================================================

  Widget buildPlayer() {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        16,
        18,
        16,
        0,
      ),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white
              .withOpacity(0.08),
        ),
      ),
      child: Column(
        children: [
          // Decorative top line
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 2,
                  color: kRed,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'PLAY',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                  color: kMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 2,
                  color: kRed,
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          buildVinylRecord(),

          const SizedBox(height: 18),

          Text(
            selectedFileName ??
                'YOUR SONG',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              color: kCream,
            ),
          ),

          const SizedBox(height: 5),

          const Text(
            'ISAI KARAOKE SESSION',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 2,
              color: kMuted,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            '${formatDuration(position)} / '
            '${formatDuration(duration)}',
            style: const TextStyle(
              color: kMuted,
              fontSize: 11,
            ),
          ),

          const SizedBox(height: 12),

          buildTimeline(),

          const SizedBox(height: 5),

          buildTransportControls(),
        ],
      ),
    );
  }

  // ==========================================================
  // TIMELINE
  // ==========================================================

  Widget buildTimeline() {
    final maxMilliseconds =
        duration.inMilliseconds > 0
            ? duration.inMilliseconds.toDouble()
            : 1.0;

    final currentMilliseconds =
        position.inMilliseconds
            .clamp(
              0,
              maxMilliseconds.toInt(),
            )
            .toDouble();

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: kRed,
            inactiveTrackColor:
                Colors.white12,
            thumbColor: kCream,
            overlayColor:
                kRed.withOpacity(0.15),
            trackHeight: 3,
            thumbShape:
                const RoundSliderThumbShape(
              enabledThumbRadius: 6,
            ),
          ),
          child: Slider(
            value: currentMilliseconds,
            min: 0,
            max: maxMilliseconds,
            onChanged: stemsReady
                ? (value) {
                    seekAll(
                      Duration(
                        milliseconds:
                            value.round(),
                      ),
                    );
                  }
                : null,
          ),
        ),
      ],
    );
  }

  // ==========================================================
  // TRANSPORT CONTROLS
  // ==========================================================

  Widget buildTransportControls() {
    return Row(
      mainAxisAlignment:
          MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: stemsReady
              ? () {
                  seekAll(
                    Duration.zero,
                  );
                }
              : null,
          icon: const Icon(
            Icons.skip_previous_rounded,
          ),
          color: kCream,
        ),

        const SizedBox(width: 14),

        GestureDetector(
          onTap:
              stemsReady ? playAll : null,
          child: Container(
            width: 66,
            height: 66,
            decoration:
                const BoxDecoration(
              shape: BoxShape.circle,
              color: kRed,
            ),
            child: Icon(
              isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: kBlack,
              size: 36,
            ),
          ),
        ),

        const SizedBox(width: 14),

        IconButton(
          onPressed: stemsReady
              ? () {
                  seekAll(
                    duration,
                  );
                }
              : null,
          icon: const Icon(
            Icons.skip_next_rounded,
          ),
          color: kCream,
        ),
      ],
    );
  }

  // ==========================================================
  // STEM CARD
  // ==========================================================

  Widget buildStemCard(
    StemData stem,
  ) {
    return Container(
      margin: const EdgeInsets.only(
        bottom: 10,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0E0E),
        borderRadius:
            BorderRadius.circular(16),
        border: Border.all(
          color: stem.muted
              ? Colors.white
                  .withOpacity(0.06)
              : Colors.white
                  .withOpacity(0.11),
        ),
      ),
      child: Row(
        children: [
          // --------------------------------------------------
          // ICON BOX
          // --------------------------------------------------

          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: stem.color,
              borderRadius:
                  BorderRadius.circular(14),
            ),
            child: Icon(
              stem.icon,
              color: kBlack,
              size: 26,
            ),
          ),

          const SizedBox(width: 12),

          // --------------------------------------------------
          // NAME + SLIDER
          // --------------------------------------------------

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  stem.name,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight:
                        FontWeight.w900,
                    letterSpacing: 1.5,
                    color: stem.muted
                        ? kMuted
                        : kCream,
                  ),
                ),

                const SizedBox(height: 2),

                SliderTheme(
                  data:
                      SliderTheme.of(context)
                          .copyWith(
                    activeTrackColor:
                        stem.color,
                    inactiveTrackColor:
                        Colors.white12,
                    thumbColor: kCream,
                    trackHeight: 3,
                    overlayColor:
                        stem.color
                            .withOpacity(0.12),
                    thumbShape:
                        const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: stem.volume,
                    min: 0,
                    max: 1,
                    onChanged: stemsReady
                        ? (value) {
                            changeStemVolume(
                              stem,
                              value,
                            );
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 5),

          // --------------------------------------------------
          // VALUE
          // --------------------------------------------------

          SizedBox(
            width: 38,
            child: Text(
              '${(stem.volume * 100).round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: kCream,
              ),
            ),
          ),

          // --------------------------------------------------
          // MUTE
          // --------------------------------------------------

          IconButton(
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(
              minWidth: 38,
              minHeight: 38,
            ),
            onPressed: stemsReady
                ? () => toggleMute(stem)
                : null,
            icon: Icon(
              stem.muted
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              color: stem.muted
                  ? kMuted
                  : kCream,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // STEM MIXER
  // ==========================================================

  Widget buildMixer() {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        16,
        18,
        16,
        0,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius:
            BorderRadius.circular(22),
        border: Border.all(
          color: kRed.withOpacity(0.65),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          // --------------------------------------------------
          // HEADER
          // --------------------------------------------------

          Row(
            children: [
              const Text(
                'STEM MIXER',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      FontWeight.w900,
                  letterSpacing: 2,
                  color: kCream,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Container(
                  height: 2,
                  color: kRed,
                ),
              ),

              const SizedBox(width: 12),

              Text(
                '${stems.length} STEMS',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  color: kCream,
                ),
              ),
            ],
          ),

          const SizedBox(height: 15),

          // --------------------------------------------------
          // STEMS
          // --------------------------------------------------

          ...stems.map(buildStemCard),

          const SizedBox(height: 5),

          // --------------------------------------------------
          // MASTER
          // --------------------------------------------------

          Container(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 9,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF0D0E0E),
              borderRadius:
                  BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: kRed,
                    borderRadius:
                        BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    color: kBlack,
                  ),
                ),

                const SizedBox(width: 12),

                const SizedBox(
                  width: 52,
                  child: Text(
                    'MASTER',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight:
                          FontWeight.w900,
                      letterSpacing: 1,
                      color: kCream,
                    ),
                  ),
                ),

                Expanded(
                  child: SliderTheme(
                    data:
                        SliderTheme.of(context)
                            .copyWith(
                      activeTrackColor:
                          kCream,
                      inactiveTrackColor:
                          Colors.white12,
                      thumbColor: kRed,
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                    ),
                    child: Slider(
                      value: masterVolume,
                      min: 0,
                      max: 1,
                      onChanged: stemsReady
                          ? changeMasterVolume
                          : null,
                    ),
                  ),
                ),

                Text(
                  '${(masterVolume * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight:
                        FontWeight.bold,
                    color: kCream,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // CONTROL SLIDER
  // ==========================================================

  Widget buildControlSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String displayValue,
    required ValueChanged<double>? onChanged,
  }) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight:
                    FontWeight.w900,
                letterSpacing: 1.5,
                color: kBlack,
              ),
            ),

            const Spacer(),

            Container(
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: kBlack,
                borderRadius:
                    BorderRadius.circular(6),
              ),
              child: Text(
                displayValue,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight:
                      FontWeight.w900,
                  color: kCream,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 3),

        SliderTheme(
          data:
              SliderTheme.of(context).copyWith(
            activeTrackColor: kBlack,
            inactiveTrackColor:
                kBlack.withOpacity(0.20),
            thumbColor: kCream,
            overlayColor:
                kBlack.withOpacity(0.12),
            trackHeight: 3,
            thumbShape:
                const RoundSliderThumbShape(
              enabledThumbRadius: 7,
            ),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),

        Row(
          mainAxisAlignment:
              MainAxisAlignment.spaceBetween,
          children: [
            Text(
              min.round().toString(),
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: kBlack,
              ),
            ),

            Text(
              '0',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: kBlack,
              ),
            ),

            Text(
              max.round().toString(),
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: kBlack,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ==========================================================
  // SONG CONTROLS
  // ==========================================================

  Widget buildControls() {
    final transposeDisplay =
        transpose == 0
            ? '0'
            : transpose > 0
                ? '+${transpose.round()}'
                : transpose.round().toString();

    final tempoDisplay =
        tempo == 0
            ? '0'
            : tempo > 0
                ? '+${tempo.round()}'
                : tempo.round().toString();

    return Container(
      margin: const EdgeInsets.fromLTRB(
        16,
        18,
        16,
        28,
      ),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kRed,
        borderRadius:
            BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          // --------------------------------------------------
          // HEADER
          // --------------------------------------------------

          Row(
            children: [
              const Text(
                'SONG CONTROLS',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      FontWeight.w900,
                  letterSpacing: 2,
                  color: kBlack,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Container(
                  height: 2,
                  color: kBlack,
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),

          // --------------------------------------------------
          // TRANSPOSE
          // --------------------------------------------------

          buildControlSlider(
            label: 'TRANSPOSE',
            value: transpose,
            min: -12,
            max: 12,
            divisions: 24,
            displayValue: transposeDisplay,
            onChanged:
                stemsReady && !isLoading
                    ? (value) {
                        setState(() {
                          transpose =
                              value.round()
                                  .toDouble();
                        });
                      }
                    : null,
          ),

          const SizedBox(height: 5),

          // --------------------------------------------------
          // APPLY TRANSPOSE
          // --------------------------------------------------

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed:
                  stemsReady && !isLoading
                      ? () {
                          applyTranspose(
                            transpose,
                          );
                        }
                      : null,
              icon: const Icon(
                Icons.music_note_rounded,
                size: 18,
              ),
              label: Text(
                isLoading
                    ? 'PROCESSING...'
                    : 'APPLY TRANSPOSE',
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor: kBlack,
                foregroundColor: kCream,
                disabledBackgroundColor:
                    Colors.black26,
                disabledForegroundColor:
                    Colors.black38,
                padding:
                    const EdgeInsets.symmetric(
                  vertical: 14,
                ),
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(4),
                ),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // --------------------------------------------------
          // TEMPO
          // --------------------------------------------------

          buildControlSlider(
            label: 'TEMPO',
            value: tempo,
            min: -100,
            max: 100,
            divisions: 200,
            displayValue: tempoDisplay,
            onChanged:
                stemsReady && !isLoading
                    ? (value) {
                        setState(() {
                          tempo =
                              value.round()
                                  .toDouble();
                        });
                      }
                    : null,
          ),

          const SizedBox(height: 5),

          // --------------------------------------------------
          // APPLY TEMPO
          // --------------------------------------------------

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed:
                  stemsReady && !isLoading
                      ? () {
                          applyTempo(
                            tempo,
                          );
                        }
                      : null,
              icon: const Icon(
                Icons.speed_rounded,
                size: 18,
              ),
              label: Text(
                isLoading
                    ? 'PROCESSING...'
                    : 'APPLY TEMPO',
              ),
              style:
                  ElevatedButton.styleFrom(
                backgroundColor: kBlack,
                foregroundColor: kCream,
                disabledBackgroundColor:
                    Colors.black26,
                disabledForegroundColor:
                    Colors.black38,
                padding:
                    const EdgeInsets.symmetric(
                  vertical: 14,
                ),
                shape:
                    RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(4),
                ),
              ),
            ),
          ),

          const SizedBox(height: 18),

          // --------------------------------------------------
          // RESET ROW
          // --------------------------------------------------

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      stemsReady &&
                              !isLoading &&
                              transpose != 0
                          ? () {
                              applyTranspose(0);
                            }
                          : null,
                  icon: const Icon(
                    Icons.undo_rounded,
                    size: 17,
                  ),
                  label: const Text(
                    'RESET KEY',
                  ),
                  style:
                      OutlinedButton.styleFrom(
                    foregroundColor: kBlack,
                    disabledForegroundColor:
                        Colors.black38,
                    side:
                        const BorderSide(
                      color: kBlack,
                    ),
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 13,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 10),

              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      stemsReady &&
                              !isLoading &&
                              tempo != 0
                          ? () {
                              applyTempo(0);
                            }
                          : null,
                  icon: const Icon(
                    Icons.undo_rounded,
                    size: 17,
                  ),
                  label: const Text(
                    'RESET TEMPO',
                  ),
                  style:
                      OutlinedButton.styleFrom(
                    foregroundColor: kBlack,
                    disabledForegroundColor:
                        Colors.black38,
                    side:
                        const BorderSide(
                      color: kBlack,
                    ),
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 13,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // --------------------------------------------------
          // REMOVE VOCALS + SAVE
          // --------------------------------------------------

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: stemsReady
                      ? toggleRemoveVocals
                      : null,
                  icon: Icon(
                    removeVocals
                        ? Icons.mic_off_rounded
                        : Icons.mic_none_rounded,
                  ),
                  label: Text(
                    removeVocals
                        ? 'VOCALS OFF'
                        : 'REMOVE VOCALS',
                  ),
                  style:
                      OutlinedButton.styleFrom(
                    foregroundColor: kBlack,
                    disabledForegroundColor:
                        Colors.black38,
                    side:
                        const BorderSide(
                      color: kBlack,
                    ),
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 14,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 10),

              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      stemsReady
                          ? saveFinalMix
                          : null,
                  icon: const Icon(
                    Icons.download_rounded,
                  ),
                  label: const Text(
                    'SAVE',
                  ),
                  style:
                      OutlinedButton.styleFrom(
                    foregroundColor: kBlack,
                    disabledForegroundColor:
                        Colors.black38,
                    side:
                        const BorderSide(
                      color: kBlack,
                    ),
                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 14,
                    ),
                    shape:
                        RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 520,
            ),
            child: ListView(
              physics:
                  const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                buildHeader(),

                buildRedLine(),

                const SizedBox(height: 12),

                buildUploadPanel(),

                buildPlayer(),

                buildMixer(),

                buildControls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}