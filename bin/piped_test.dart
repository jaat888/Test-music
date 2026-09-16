// bin/piped_test.dart
//
// SurSathi app ke search + audio-URL resolve logic ka standalone copy —
// sirf testing ke liye.
//
// *** ARCHITECTURE (3 LAYERS, sab independent — ek block ho to doosra try hota hai) ***
//
// SEARCH:
//   Layer 1: dart_ytmusic_api  — YT Music ka apna hi search (music_songs
//            jaisa filter, Piped ke `filter: music_songs` se better match
//            kyunki ye YT Music ka native ranking use karta hai).
//   Layer 2: youtube_explode_dart search — agar YT Music search fail ho.
//
// AUDIO URL:
//   Layer 1: youtube_explode_dart — seedha YouTube se extract (multiple
//            client surfaces: ios/androidVr/safari + Deno JS-solver).
//   Layer 2: Piped public instances (parallel race) — BACKUP. In dono me
//            koi bhi single point of failure share nahi karta, isliye agar
//            YouTube kal Layer 1 ka koi client block kare, Piped instances
//            (agar kabhi wapas zinda hue) fallback ban sakte hain. NOTE:
//            abhi (Sept 2026) ye poore ecosystem-wide down hain (dekh
//            README/pichli test-run logs) — isliye isse "free extra try"
//            treat karo, hard dependency nahi.
//
// Kyu alag repo/file: SurSathi Flutter app hai, uski APK build karke test
// karne me 2-3 minute lagte hain. Ye plain Dart script hai, GitHub Actions
// pe ~15-20 sec me chal jaati hai.
//
// WORKFLOW: (README.md me detail hai)
//   1. Yahan aur SurSathi ke youtube_service.dart me — dono jagah change karo.
//   2. Zip karke push karo, Actions "Test Piped Logic" dekho.
//   3. PASS ho jaaye tabhi verified logic asli app me daalo.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:dart_ytmusic_api/yt_music.dart';

const String kTestQuery = 'arijit singh';
const String kTestVideoId = 'dQw4w9WgXcQ'; // hamesha-available public video

void log(String msg) => stdout.writeln(msg);

// =====================================================================
// SEARCH — Layer 1: dart_ytmusic_api
// =====================================================================

Future<List<Map<String, dynamic>>> _searchViaYtMusic(String query) async {
  log('  [search/ytmusic] querying YT Music for "$query" ...');
  try {
    final ytmusic = YTMusic();
    await ytmusic.initialize();
    final songs = await ytmusic.searchSongs(query);
    final list = songs
        .take(10)
        .map((s) => {
              'id': s.videoId,
              'title': s.name,
              'author': s.artist.name,
            })
        .where((m) => m['id'] != null && (m['id'] as String).isNotEmpty)
        .toList();
    if (list.isEmpty) {
      log('  [search/ytmusic] 0 usable results');
      return [];
    }
    log('  [search/ytmusic] OK, ${list.length} results');
    return list;
  } catch (e) {
    log('  [search/ytmusic] error: $e');
    return [];
  }
}

// =====================================================================
// SEARCH — Layer 2: youtube_explode_dart (fallback)
// =====================================================================

Future<List<Map<String, dynamic>>> _searchViaExplode(
    YoutubeExplode yt, String query) async {
  log('  [search/explode] querying YouTube directly for "$query" ...');
  try {
    final results = await yt.search.getVideos(query);
    final list = results
        .take(10)
        .map((v) => {
              'id': v.id.value,
              'title': v.title,
              'author': v.author,
              'duration': v.duration?.inSeconds,
            })
        .toList();
    log('  [search/explode] OK, ${list.length} results');
    return list;
  } catch (e) {
    log('  [search/explode] error: $e');
    return [];
  }
}

Future<List<Map<String, dynamic>>> search(YoutubeExplode yt, String query) async {
  final fromYtMusic = await _searchViaYtMusic(query);
  if (fromYtMusic.isNotEmpty) return fromYtMusic;
  log('  [search] YT Music se kuch nahi mila, explode fallback try kar rahe hain...');
  return _searchViaExplode(yt, query);
}

// =====================================================================
// Verify a candidate URL is actually fetchable (dono layers isse use karte hain)
// =====================================================================

Future<bool> verifyPlayable(String url) async {
  try {
    final res = await _httpClient.get(
      Uri.parse(url),
      headers: {'Range': 'bytes=0-1023'},
    ).timeout(const Duration(seconds: 8));
    return res.statusCode == 200 || res.statusCode == 206;
  } catch (e) {
    log('  [verify] failed: $e');
    return false;
  }
}

// =====================================================================
// AUDIO URL — Layer 1: youtube_explode_dart
// =====================================================================

Future<String?> _audioViaExplode(YoutubeExplode yt, String videoId) async {
  try {
    log('  [audio/explode] resolving manifest for $videoId ...');
    final manifest = await yt.videos.streams.getManifest(
      videoId,
      ytClients: [
        YoutubeApiClient.ios,
        YoutubeApiClient.androidVr,
        YoutubeApiClient.safari,
      ],
    );
    final audioStreams = manifest.audioOnly;
    if (audioStreams.isEmpty) {
      log('  [audio/explode] no audio-only streams in manifest');
      return null;
    }
    final best = audioStreams.withHighestBitrate();
    log('  [audio/explode] best candidate: ${best.bitrate}, verifying...');
    if (!await verifyPlayable(best.url.toString())) {
      log('  [audio/explode] verify FAILED');
      return null;
    }
    log('  [audio/explode] OK!');
    return best.url.toString();
  } catch (e) {
    log('  [audio/explode] error: $e');
    return null;
  }
}

// =====================================================================
// AUDIO URL — Layer 2: Piped public instances (BACKUP, parallel race)
// =====================================================================
//
// Ye list abhi (Sept 2026) ecosystem-wide down hai (YouTube crackdown) —
// isliye ise hard dependency mat samjho. Lekin free/cheap backup hai: agar
// koi instance kabhi wapas zinda ho jaaye, ya youtube_explode_dart ka
// koi client kal block ho jaaye, ye extra safety net ka kaam karega.
const List<String> kPipedBackupInstances = [
  'https://pipedapi.kavin.rocks',
  'https://pipedapi-libre.kavin.rocks',
  'https://pipedapi.tokhmi.xyz',
  'https://pipedapi.moomoo.me',
  'https://pipedapi.syncpundit.io',
  'https://api-piped.mha.fi',
  'https://piped-api.garudalinux.org',
  'https://pipedapi.rivo.lol',
  'https://pipedapi.leptons.xyz',
  'https://piped-api.lunar.icu',
  'https://ytapi.dc09.ru',
  'https://pipedapi.colinslegacy.com',
  'https://yapi.vyper.me',
  'https://api.looleh.xyz',
  'https://piped-api.cfe.re',
  'https://pipedapi.r4fo.com',
];

final http.Client _httpClient = http.Client();

Future<T?> _raceFirstSuccess<T>(
  List<String> instances,
  Future<T?> Function(String base) attempt,
) async {
  if (instances.isEmpty) return null;
  final completer = Completer<T?>();
  var remaining = instances.length;

  for (final base in instances) {
    attempt(base).then((result) {
      if (completer.isCompleted) return;
      if (result != null) {
        completer.complete(result);
      } else {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) completer.complete(null);
      }
    }).catchError((e) {
      if (completer.isCompleted) return;
      remaining--;
      if (remaining == 0 && !completer.isCompleted) completer.complete(null);
    });
  }
  return completer.future;
}

Future<String?> _pipedAudioOne(String base, String videoId) async {
  log('  [audio/piped-backup] trying $base ...');
  try {
    final uri = Uri.parse('$base/streams/$videoId');
    final res = await _httpClient.get(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      log('  [audio/piped-backup] $base -> HTTP ${res.statusCode}');
      return null;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final audioStreams = (data['audioStreams'] as List?) ?? [];
    if (audioStreams.isEmpty) return null;
    final sorted = List<Map<String, dynamic>>.from(audioStreams)
      ..sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    final url = sorted.first['url'] as String?;
    if (url == null) return null;
    if (!await verifyPlayable(url)) {
      log('  [audio/piped-backup] $base -> verify FAILED');
      return null;
    }
    log('  [audio/piped-backup] $base -> OK!');
    return url;
  } catch (e) {
    log('  [audio/piped-backup] $base -> error: $e');
    return null;
  }
}

Future<String?> _audioViaPipedBackup(String videoId) async {
  log('  [audio] youtube_explode se nahi mila, Piped backup try kar rahe hain (${kPipedBackupInstances.length} instances, parallel)...');
  return _raceFirstSuccess<String>(
      kPipedBackupInstances, (base) => _pipedAudioOne(base, videoId));
}

Future<String?> getAudioUrl(YoutubeExplode yt, String videoId) async {
  final viaExplode = await _audioViaExplode(yt, videoId);
  if (viaExplode != null) return viaExplode;
  return _audioViaPipedBackup(videoId);
}

// =====================================================================
// Main
// =====================================================================

Future<void> main(List<String> args) async {
  final query = args.isNotEmpty ? args[0] : kTestQuery;
  final videoId = args.length > 1 ? args[1] : kTestVideoId;

  var failed = false;

  log('===== SETUP: init Deno JS solver =====');
  YoutubeExplode yt;
  try {
    final solver = await DenoEJSSolver.init();
    yt = YoutubeExplode(jsSolver: solver);
    log('  [setup] Deno solver ready');
  } catch (e) {
    log('  [setup] Deno solver init failed ($e) — bina solver ke aage badh rahe hain');
    yt = YoutubeExplode();
  }

  log('');
  log('===== TEST 1: search("$query") =====');
  final results = await search(yt, query);
  if (results.isEmpty) {
    log('RESULT: FAIL — dono layers (YT Music + explode) se 0 results');
    failed = true;
  } else {
    log('RESULT: PASS — ${results.length} results, pehla: ${results.first}');
  }

  log('');
  log('===== TEST 2: getAudioUrl("$videoId") =====');
  final url = await getAudioUrl(yt, videoId);
  if (url == null) {
    log('RESULT: FAIL — dono layers (explode + Piped backup) se playable URL nahi mila');
    failed = true;
  } else {
    final shown = url.length > 100 ? '${url.substring(0, 100)}...' : url;
    log('RESULT: PASS — $shown');
  }

  yt.close();
  _httpClient.close();

  log('');
  if (failed) {
    log('OVERALL: FAIL ❌');
    exit(1);
  } else {
    log('OVERALL: PASS ✅');
    exit(0);
  }
}
