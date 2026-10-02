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
// APP
// ============================================================

class MusiqApp extends StatelessWidget {
  const MusiqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Musiq',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor:
            const Color(0xFF0B0C0F),
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA855F7),
          brightness: Brightness.dark,
        ),
      ),
      home: const SoundMixerPage(),
    );
  }
}


// ============================================================
// STEM DATA
// ============================================================

class StemData {
  final String name;
  final String icon;
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
  State<SoundMixerPage> createState() =>
      _SoundMixerPageState();
}


class _SoundMixerPageState
    extends State<SoundMixerPage> {

  // ==========================================================
  // BACKEND
  // ==========================================================

  static const String backendUrl =
      'http://127.0.0.1:8000';


  // ==========================================================
  // AUDIO PLAYERS
  // ==========================================================

  final AudioPlayer vocalsPlayer =
      AudioPlayer();

  final AudioPlayer drumsPlayer =
      AudioPlayer();

  final AudioPlayer bassPlayer =
      AudioPlayer();

  final AudioPlayer otherPlayer =
      AudioPlayer();


  late final List<StemData> stems;


  // ==========================================================
  // STREAMS
  // ==========================================================

  StreamSubscription<Duration>?
      _positionSubscription;

  StreamSubscription<Duration?>?
      _durationSubscription;


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

  // Current applied transpose.
  double transpose = 0.0;


  String statusMessage =
      'Upload a song to begin';


  // ==========================================================
  // INIT
  // ==========================================================

  @override
  void initState() {
    super.initState();


    stems = [

      StemData(
        name: 'Vocals',
        icon: '🎤',
        color: const Color(0xFFFF40DA),
        player: vocalsPlayer,
      ),

      StemData(
        name: 'Drums',
        icon: '🥁',
        color: const Color(0xFFFF681A),
        player: drumsPlayer,
      ),

      StemData(
        name: 'Bass',
        icon: '🎸',
        color: const Color(0xFFA855F7),
        player: bassPlayer,
      ),

      StemData(
        name: 'Other',
        icon: '🎹',
        color: const Color(0xFF4CC9F0),
        player: otherPlayer,
      ),
    ];


    // ========================================================
    // PLAYBACK POSITION
    // ========================================================

    _positionSubscription =
        vocalsPlayer.onPositionChanged.listen(
      (newPosition) {

        if (!mounted) return;

        setState(() {
          position = newPosition;
        });
      },
    );


    // ========================================================
    // SONG DURATION
    // ========================================================

    _durationSubscription =
        vocalsPlayer.onDurationChanged.listen(
      (newDuration) {

        if (!mounted) return;

        setState(() {
          duration = newDuration;
        });
      },
    );
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

      final result =
          await FilePicker.platform.pickFiles(
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


      if (
        result == null ||
        result.files.isEmpty
      ) {
        return;
      }


      final file =
          result.files.first;


      if (file.bytes == null) {

        setState(() {
          statusMessage =
              'Could not read the selected file.';
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

        statusMessage =
            'Uploading song...';
      });


      await stopAll();


      // ======================================================
      // SEND SONG TO BACKEND
      // ======================================================

      final request =
          http.MultipartRequest(
        'POST',
        Uri.parse(
          '$backendUrl/separate',
        ),
      );


      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ),
      );


      final streamedResponse =
          await request.send();


      final response =
          await http.Response.fromStream(
        streamedResponse,
      );


      if (response.statusCode != 200) {

        String errorMessage =
            'Backend error (${response.statusCode})';


        try {

          final errorJson =
              jsonDecode(response.body);

          if (
            errorJson is Map &&
            errorJson['detail'] != null
          ) {

            errorMessage =
                errorJson['detail'].toString();
          }

        } catch (_) {}


        throw Exception(errorMessage);
      }


      final data =
          jsonDecode(response.body);


      final Map<String, dynamic>
          stemUrls =
          Map<String, dynamic>.from(
        data['stems'],
      );


      jobId =
          data['job_id']?.toString();


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
        statusMessage =
            'Loading 4 separated stems...';
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

        statusMessage =
            '4 stems ready';
      });

    } catch (e) {

      await stopAll();

      if (!mounted) return;

      setState(() {

        isLoading = false;
        stemsReady = false;
        isPlaying = false;

        statusMessage =
            'Error: $e';
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

    final fullUrl =
        '$backendUrl$relativeUrl';

    await player.setSourceUrl(
      fullUrl,
    );
  }


  // ==========================================================
  // APPLY TRANSPOSE
  // ==========================================================

  Future<void> applyTranspose(
    double semitones,
  ) async {

    if (
      !stemsReady ||
      jobId == null
    ) {
      return;
    }


    // Force slider value to an integer
    // because the backend uses semitone steps.

    final int requestedSemitones =
        semitones.round();


    try {

      setState(() {

        isLoading = true;
        isPlaying = false;

        statusMessage =
            requestedSemitones == 0
                ? 'Restoring original pitch...'
                : 'Transposing to '
                  '${requestedSemitones > 0 ? '+' : ''}'
                  '$requestedSemitones semitones...';
      });


      await stopAll();


      // ======================================================
      // CALL BACKEND
      // ======================================================

      final response =
          await http.post(

        Uri.parse(
          '$backendUrl/transpose',
        ),

        headers: {
          'Content-Type':
              'application/json',
        },

        body: jsonEncode({

          'job_id': jobId,

          'semitones':
              requestedSemitones,
        }),
      );


      if (response.statusCode != 200) {

        String message =
            'Transpose failed';


        try {

          final error =
              jsonDecode(response.body);

          if (
            error is Map &&
            error['detail'] != null
          ) {

            message =
                error['detail'].toString();
          }

        } catch (_) {}


        throw Exception(message);
      }


      final data =
          jsonDecode(response.body);


      final Map<String, dynamic>
          stemUrls =
          Map<String, dynamic>.from(
        data['stems'],
      );


      // ======================================================
      // VERIFY RESPONSE
      // ======================================================

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
      // LOAD TRANSPOSED FOUR STEMS
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
      // RESTORE VOLUME / MUTE SETTINGS
      // ======================================================

      for (final stem in stems) {

        await stem.player.setVolume(
          stem.muted
              ? 0.0
              : stem.volume *
                masterVolume,
        );
      }


      if (!mounted) return;


      setState(() {

        transpose =
            requestedSemitones.toDouble();

        isLoading = false;
        isPlaying = false;

        position = Duration.zero;

        statusMessage =
            requestedSemitones == 0
                ? 'Original pitch restored'
                : 'Transpose '
                  '${requestedSemitones > 0 ? '+' : ''}'
                  '$requestedSemitones semitones applied';
      });

    } catch (e) {

      if (!mounted) return;

      setState(() {

        isLoading = false;
        isPlaying = false;

        statusMessage =
            'Transpose error: $e';
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
        statusMessage =
            'Playing...';
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

        statusMessage =
            'Playback error: $e';

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

      statusMessage =
          'Paused';
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
          : stem.volume *
            masterVolume,
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
            : stem.volume *
              masterVolume,
      );
    }
  }


  // ==========================================================
  // REMOVE VOCALS
  // ==========================================================

  Future<void> toggleRemoveVocals() async {

    setState(() {
      removeVocals =
          !removeVocals;
    });


    final vocals =
        stems.first;


    await vocals.player.setVolume(

      removeVocals
          ? 0.0
          : vocals.volume *
            masterVolume,
    );
  }


  // ==========================================================
  // FORMAT TIME
  // ==========================================================

  String formatDuration(
    Duration value,
  ) {

    final minutes =
        value.inMinutes;

    final seconds =
        value.inSeconds % 60;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }


  // ==========================================================
  // SAVE FINAL MIX
  // ==========================================================

  Future<void> saveFinalMix() async {

    if (
      !stemsReady ||
      jobId == null
    ) {
      return;
    }


    try {

      setState(() {
        statusMessage =
            'Saving final mix...';
      });


      final stemSettings =
          <String, dynamic>{};


      for (final stem in stems) {

        final key =
            stem.name.toLowerCase();


        stemSettings[key] = {

          'volume':
              stem.volume,

          'muted':
              stem.muted,
        };
      }


      // Remove vocals button
      // overrides the vocal settings.

      if (removeVocals) {

        stemSettings['vocals'] = {

          'volume': 0.0,

          'muted': true,
        };
      }


      // ======================================================
      // SEND EXPORT REQUEST
      // ======================================================

      final response =
          await http.post(

        Uri.parse(
          '$backendUrl/export',
        ),

        headers: {
          'Content-Type':
              'application/json',
        },

        body: jsonEncode({

          'job_id':
              jobId,

          'master_volume':
              masterVolume,

          'semitones':
              transpose.round(),

          'stems':
              stemSettings,
        }),
      );


      if (response.statusCode != 200) {

        String message =
            'Export failed';


        try {

          final error =
              jsonDecode(response.body);

          if (
            error is Map &&
            error['detail'] != null
          ) {

            message =
                error['detail'].toString();
          }

        } catch (_) {}


        throw Exception(message);
      }


      final data =
          jsonDecode(response.body);


      final downloadUrl =
          '$backendUrl'
          '${data['download_url']}';


      // ======================================================
      // BROWSER DOWNLOAD
      // ======================================================

      final anchor =
          html.AnchorElement(
            href: downloadUrl,
          )
            ..setAttribute(
              'download',
              'Musiq_Final.mp3',
            )
            ..style.display = 'none';


      html.document.body
          ?.children
          .add(anchor);


      anchor.click();

      anchor.remove();


      if (!mounted) return;


      setState(() {

        statusMessage =
            'Final mix saved!';
      });


      ScaffoldMessenger
          .of(context)
          .showSnackBar(

        const SnackBar(
          content: Text(
            'Musiq_Final.mp3 downloaded successfully',
          ),
        ),
      );

    } catch (e) {

      if (!mounted) return;


      setState(() {

        statusMessage =
            'Save failed';
      });


      ScaffoldMessenger
          .of(context)
          .showSnackBar(

        SnackBar(
          content: Text(
            'Save failed: $e',
          ),
        ),
      );
    }
  }


  // ==========================================================
  // HEADER
  // ==========================================================

  Widget buildHeader() {

    return Padding(

      padding:
          const EdgeInsets.fromLTRB(
        28,
        22,
        28,
        12,
      ),

      child: Row(

        children: [

          const Text(
            'MUSIQ',
            style: TextStyle(
              fontSize: 24,
              fontWeight:
                  FontWeight.w800,
              letterSpacing: 3,
            ),
          ),

          const Spacer(),

          Container(

            padding:
                const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),

            decoration:
                BoxDecoration(
              color:
                  const Color(0xFF17181E),
              borderRadius:
                  BorderRadius.circular(20),
              border: Border.all(
                color:
                    Colors.white
                        .withOpacity(0.08),
              ),
            ),

            child: Text(

              stemsReady
                  ? '● READY'
                  : '● OFFLINE',

              style: TextStyle(

                fontSize: 11,

                fontWeight:
                    FontWeight.bold,

                color: stemsReady
                    ? const Color(
                        0xFF70E000,
                      )
                    : Colors.white54,
              ),
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

      margin:
          const EdgeInsets.symmetric(
        horizontal: 28,
      ),

      padding:
          const EdgeInsets.all(22),

      decoration:
          BoxDecoration(

        gradient:
            const LinearGradient(

          colors: [

            Color(0xFF18121F),

            Color(0xFF121318),
          ],
        ),

        borderRadius:
            BorderRadius.circular(24),

        border: Border.all(

          color:
              const Color(0xFFA855F7)
                  .withOpacity(0.25),
        ),
      ),

      child: Row(

        children: [

          Container(

            width: 62,
            height: 62,

            decoration:
                BoxDecoration(

              color:
                  const Color(0xFFA855F7)
                      .withOpacity(0.15),

              borderRadius:
                  BorderRadius.circular(18),
            ),

            child:
                const Icon(

              Icons.music_note_rounded,

              color:
                  Color(0xFFA855F7),

              size: 30,
            ),
          ),

          const SizedBox(width: 18),

          Expanded(

            child: Column(

              crossAxisAlignment:
                  CrossAxisAlignment.start,

              children: [

                Text(

                  selectedFileName ??
                      'No song selected',

                  maxLines: 1,

                  overflow:
                      TextOverflow.ellipsis,

                  style:
                      const TextStyle(

                    fontSize: 16,

                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 5),

                Text(

                  statusMessage,

                  maxLines: 2,

                  overflow:
                      TextOverflow.ellipsis,

                  style:
                      const TextStyle(

                    color:
                        Colors.white54,

                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 15),

          ElevatedButton.icon(

            onPressed:
                isLoading
                    ? null
                    : pickSong,

            icon:

                isLoading

                    ? const SizedBox(

                        width: 17,
                        height: 17,

                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )

                    : const Icon(
                        Icons.upload_rounded,
                      ),

            label:

                Text(
                  isLoading
                      ? 'PROCESSING'
                      : 'UPLOAD SONG',
                ),

            style:
                ElevatedButton.styleFrom(

              backgroundColor:
                  const Color(
                0xFFA855F7,
              ),

              foregroundColor:
                  Colors.white,

              padding:
                  const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 15,
              ),

              shape:
                  RoundedRectangleBorder(

                borderRadius:
                    BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }


  // ==========================================================
  // TURN TABLE
  // ==========================================================

  Widget buildTurntable() {

    return Container(

      width:
          double.infinity,

      margin:
          const EdgeInsets.fromLTRB(
        28,
        18,
        28,
        0,
      ),

      padding:
          const EdgeInsets.all(25),

      decoration:
          BoxDecoration(

        color:
            const Color(0xFF121318),

        borderRadius:
            BorderRadius.circular(24),

        border: Border.all(
          color:
              Colors.white
                  .withOpacity(0.06),
        ),
      ),

      child: Column(

        children: [

          Container(

            width: 245,
            height: 245,

            decoration:
                BoxDecoration(

              shape:
                  BoxShape.circle,

              gradient:
                  const RadialGradient(

                colors: [

                  Color(0xFF3B3B44),

                  Color(0xFF15151A),

                  Color(0xFF08090B),
                ],
              ),

              boxShadow: [

                BoxShadow(

                  color:
                      const Color(
                    0xFFA855F7,
                  ).withOpacity(0.18),

                  blurRadius: 35,

                  spreadRadius: 4,
                ),
              ],
            ),

            child: Center(

              child: Container(

                width: 82,
                height: 82,

                decoration:
                    const BoxDecoration(

                  shape:
                      BoxShape.circle,

                  gradient:
                      LinearGradient(

                    colors: [

                      Color(0xFFFF40DA),

                      Color(0xFFA855F7),
                    ],
                  ),
                ),

                child:
                    const Icon(

                  Icons.music_note_rounded,

                  size: 38,

                  color:
                      Colors.white,
                ),
              ),
            ),
          ),

          const SizedBox(height: 18),

          Text(

            selectedFileName ??
                'Your song',

            maxLines: 1,

            overflow:
                TextOverflow.ellipsis,

            style:
                const TextStyle(

              fontWeight:
                  FontWeight.bold,

              fontSize: 18,
            ),
          ),

          const SizedBox(height: 6),

          Text(

            '${formatDuration(position)} / '
            '${formatDuration(duration)}',

            style:
                const TextStyle(

              color:
                  Colors.white54,

              fontSize: 12,
            ),
          ),
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
            ? duration.inMilliseconds
                .toDouble()
            : 1.0;


    final currentMilliseconds =
        position.inMilliseconds
            .clamp(
              0,
              maxMilliseconds.toInt(),
            )
            .toDouble();


    return Padding(

      padding:
          const EdgeInsets.fromLTRB(
        28,
        18,
        28,
        0,
      ),

      child: Column(

        children: [

          SliderTheme(

            data:
                SliderTheme.of(context)
                    .copyWith(

              activeTrackColor:
                  const Color(
                0xFFA855F7,
              ),

              inactiveTrackColor:
                  Colors.white12,

              thumbColor:
                  const Color(
                0xFFFF40DA,
              ),

              overlayColor:
                  const Color(
                0xFFA855F7,
              ).withOpacity(0.15),

              trackHeight: 4,
            ),

            child: Slider(

              value:
                  currentMilliseconds,

              min: 0,

              max:
                  maxMilliseconds,

              onChanged:

                  stemsReady

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

          Row(

            mainAxisAlignment:
                MainAxisAlignment.spaceBetween,

            children: [

              Text(
                formatDuration(position),
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 11,
                ),
              ),

              Text(
                formatDuration(duration),
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ==========================================================
  // PLAY BUTTON
  // ==========================================================

  Widget buildPlayButton() {

    return Padding(

      padding:
          const EdgeInsets.symmetric(
        vertical: 16,
      ),

      child: GestureDetector(

        onTap:
            stemsReady
                ? playAll
                : null,

        child: Container(

          width: 72,
          height: 72,

          decoration:
              BoxDecoration(

            shape:
                BoxShape.circle,

            gradient:

                stemsReady

                    ? const LinearGradient(

                        colors: [

                          Color(0xFFFF40DA),

                          Color(0xFFA855F7),
                        ],
                      )

                    : const LinearGradient(

                        colors: [

                          Color(0xFF33343A),

                          Color(0xFF222329),
                        ],
                      ),

            boxShadow:

                stemsReady

                    ? [

                        BoxShadow(

                          color:
                              const Color(
                            0xFFA855F7,
                          ).withOpacity(0.35),

                          blurRadius: 25,

                          spreadRadius: 3,
                        ),
                      ]

                    : [],
          ),

          child: Icon(

            isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,

            size: 38,

            color:
                Colors.white,
          ),
        ),
      ),
    );
  }


  // ==========================================================
  // STEM CARD
  // ==========================================================

  Widget buildStemCard(
    StemData stem,
  ) {

    return Container(

      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),

      padding:
          const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 13,
      ),

      decoration:
          BoxDecoration(

        color:
            const Color(0xFF15161B),

        borderRadius:
            BorderRadius.circular(17),

        border: Border.all(

          color:

              stem.muted

                  ? Colors.white
                      .withOpacity(0.04)

                  : stem.color
                      .withOpacity(0.18),
        ),
      ),

      child: Row(

        children: [

          Container(

            width: 45,
            height: 45,

            decoration:
                BoxDecoration(

              color:
                  stem.color
                      .withOpacity(0.12),

              borderRadius:
                  BorderRadius.circular(13),
            ),

            child: Center(

              child: Text(

                stem.icon,

                style:
                    const TextStyle(
                  fontSize: 20,
                ),
              ),
            ),
          ),

          const SizedBox(width: 13),

          SizedBox(

            width: 75,

            child: Text(

              stem.name,

              style:
                  TextStyle(

                fontWeight:
                    FontWeight.bold,

                color:

                    stem.muted
                        ? Colors.white38
                        : Colors.white,
              ),
            ),
          ),

          Expanded(

            child: SliderTheme(

              data:
                  SliderTheme.of(context)
                      .copyWith(

                activeTrackColor:
                    stem.color,

                inactiveTrackColor:
                    Colors.white10,

                thumbColor:
                    stem.color,

                trackHeight: 4,
              ),

              child: Slider(

                value:
                    stem.volume,

                min: 0,

                max: 1,

                onChanged:

                    stemsReady

                        ? (value) {

                            changeStemVolume(
                              stem,
                              value,
                            );
                          }

                        : null,
              ),
            ),
          ),

          SizedBox(

            width: 45,

            child: Text(

              '${(stem.volume * 100).round()}%',

              textAlign:
                  TextAlign.right,

              style:
                  const TextStyle(

                color:
                    Colors.white54,

                fontSize: 11,
              ),
            ),
          ),

          const SizedBox(width: 8),

          IconButton(

            tooltip:
                stem.muted
                    ? 'Unmute'
                    : 'Mute',

            onPressed:

                stemsReady

                    ? () {
                        toggleMute(stem);
                      }

                    : null,

            icon: Icon(

              stem.muted
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,

              color:

                  stem.muted
                      ? Colors.white30
                      : stem.color,
            ),
          ),
        ],
      ),
    );
  }


  // ==========================================================
  // MIXER
  // ==========================================================

  Widget buildMixer() {

    return Container(

      margin:
          const EdgeInsets.fromLTRB(
        28,
        18,
        28,
        0,
      ),

      padding:
          const EdgeInsets.all(20),

      decoration:
          BoxDecoration(

        color:
            const Color(0xFF101116),

        borderRadius:
            BorderRadius.circular(24),

        border: Border.all(
          color:
              Colors.white
                  .withOpacity(0.06),
        ),
      ),

      child: Column(

        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [

          const Text(

            'STEM MIXER',

            style:
                TextStyle(

              letterSpacing: 2,

              fontSize: 12,

              fontWeight:
                  FontWeight.bold,

              color:
                  Colors.white54,
            ),
          ),

          const SizedBox(height: 14),

          ...stems.map(
            buildStemCard,
          ),

          const SizedBox(height: 8),

          Row(

            children: [

              const Icon(

                Icons.volume_up_rounded,

                size: 17,

                color:
                    Colors.white54,
              ),

              const SizedBox(width: 10),

              const Text(

                'MASTER',

                style:
                    TextStyle(

                  color:
                      Colors.white54,

                  fontSize: 11,

                  fontWeight:
                      FontWeight.bold,
                ),
              ),

              Expanded(

                child: SliderTheme(

                  data:
                      SliderTheme.of(context)
                          .copyWith(

                    activeTrackColor:
                        Colors.white,

                    inactiveTrackColor:
                        Colors.white10,

                    thumbColor:
                        Colors.white,

                    trackHeight: 3,
                  ),

                  child: Slider(

                    value:
                        masterVolume,

                    min: 0,

                    max: 1,

                    onChanged:

                        stemsReady
                            ? changeMasterVolume
                            : null,
                  ),
                ),
              ),

              Text(

                '${(masterVolume * 100).round()}%',

                style:
                    const TextStyle(

                  color:
                      Colors.white54,

                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }


  // ==========================================================
  // CONTROLS
  // ==========================================================

  Widget buildControls() {

    return Container(

      margin:
          const EdgeInsets.fromLTRB(
        28,
        18,
        28,
        28,
      ),

      padding:
          const EdgeInsets.all(20),

      decoration:
          BoxDecoration(

        color:
            const Color(0xFF15161B),

        borderRadius:
            BorderRadius.circular(22),

        border: Border.all(
          color:
              Colors.white
                  .withOpacity(0.06),
        ),
      ),

      child: Column(

        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [

          const Text(

            'SONG CONTROLS',

            style:
                TextStyle(

              letterSpacing: 2,

              fontSize: 12,

              fontWeight:
                  FontWeight.bold,

              color:
                  Colors.white54,
            ),
          ),

          const SizedBox(height: 18),

          // ==================================================
          // TRANSPOSE
          // ==================================================

          Row(

            children: [

              const Text(

                'TRANSPOSE',

                style:
                    TextStyle(

                  fontSize: 11,

                  color:
                      Colors.white54,
                ),
              ),

              Expanded(

                child: SliderTheme(

                  data:
                      SliderTheme.of(context)
                          .copyWith(

                    activeTrackColor:
                        const Color(
                      0xFFA855F7,
                    ),

                    inactiveTrackColor:
                        Colors.white10,

                    thumbColor:
                        const Color(
                      0xFFFF40DA,
                    ),
                  ),

                  child: Slider(

                    value:
                        transpose,

                    min: -12,

                    max: 12,

                    divisions: 24,

                    onChanged:

                        stemsReady &&
                                !isLoading

                            ? (value) {

                                setState(() {

                                  transpose =
                                      value.round()
                                          .toDouble();
                                });
                              }

                            : null,
                  ),
                ),
              ),

              SizedBox(

                width: 50,

                child: Text(

                  transpose == 0

                      ? '0'

                      : transpose > 0

                          ? '+${transpose.round()}'

                          : transpose
                              .round()
                              .toString(),

                  textAlign:
                      TextAlign.right,

                  style:
                      const TextStyle(

                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(width: 4),

              IconButton(

                tooltip:
                    'Return to original key',

                onPressed:

                    stemsReady &&
                            !isLoading &&
                            transpose != 0

                        ? () {
                            applyTranspose(0);
                          }

                        : null,

                icon:
                    const Icon(
                  Icons.undo_rounded,
                  size: 20,
                ),

                color:
                    const Color(
                  0xFFFF40DA,
                ),

                disabledColor:
                    Colors.white12,
              ),
            ],
          ),

          const SizedBox(height: 10),

          // ==================================================
          // APPLY TRANSPOSE
          // ==================================================

          SizedBox(

            width:
                double.infinity,

            child:
                ElevatedButton.icon(

              onPressed:

                  stemsReady &&
                          !isLoading

                      ? () {
                          applyTranspose(
                            transpose,
                          );
                        }

                      : null,

              icon:
                  const Icon(
                Icons.music_note_rounded,
              ),

              label:

                  Text(

                isLoading
                    ? 'PROCESSING...'
                    : 'APPLY TRANSPOSE',
              ),

              style:
                  ElevatedButton.styleFrom(

                backgroundColor:
                    const Color(
                  0xFFA855F7,
                ),

                foregroundColor:
                    Colors.white,

                disabledBackgroundColor:
                    Colors.white10,

                disabledForegroundColor:
                    Colors.white30,

                padding:
                    const EdgeInsets.symmetric(
                  vertical: 14,
                ),

                shape:
                    RoundedRectangleBorder(

                  borderRadius:
                      BorderRadius.circular(13),
                ),
              ),
            ),
          ),

          const SizedBox(height: 15),

          // ==================================================
          // REMOVE VOCALS + SAVE
          // ==================================================

          Row(

            children: [

              Expanded(

                child:
                    OutlinedButton.icon(

                  onPressed:
                      stemsReady
                          ? toggleRemoveVocals
                          : null,

                  icon:
                      const Icon(
                    Icons.mic_off_rounded,
                  ),

                  label:

                      Text(

                    removeVocals
                        ? 'VOCALS REMOVED'
                        : 'REMOVE VOCALS',
                  ),

                  style:
                      OutlinedButton.styleFrom(

                    foregroundColor:

                        removeVocals
                            ? const Color(
                                0xFFFF40DA,
                              )
                            : Colors.white,

                    side:
                        BorderSide(

                      color:

                          removeVocals
                              ? const Color(
                                  0xFFFF40DA,
                                )
                              : Colors.white24,
                    ),

                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 15,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              Expanded(

                child:
                    OutlinedButton.icon(

                  onPressed:
                      stemsReady
                          ? saveFinalMix
                          : null,

                  icon:
                      const Icon(
                    Icons.download_rounded,
                  ),

                  label:
                      const Text(
                    'SAVE',
                  ),

                  style:
                      OutlinedButton.styleFrom(

                    foregroundColor:
                        Colors.white,

                    side:
                        const BorderSide(
                      color:
                          Colors.white24,
                    ),

                    padding:
                        const EdgeInsets.symmetric(
                      vertical: 15,
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
  Widget build(
    BuildContext context,
  ) {

    return Scaffold(

      body: SafeArea(

        child: Center(

          child: ConstrainedBox(

            constraints:
                const BoxConstraints(
              maxWidth: 1050,
            ),

            child: ListView(

              children: [

                buildHeader(),

                buildUploadPanel(),

                buildTurntable(),

                buildTimeline(),

                buildPlayButton(),

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