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
// videoId sanity check + self-heal
// =====================================================================
//
// dart_ytmusic_api khud "early development, may be unstable" bolta hai —
// dekha gaya ki iska videoId field kabhi-kabhi corrupt/wrong nikalta hai
// (title/author sahi hote hain, par ID exist hi nahi karta asli YouTube
// par). Isliye streaming ke liye use karne se pehle ID ko verify karo;
// agar galat nikle to title+author se ek fresh, guaranteed-real explode
// search karke sahi ID le lo.
Future<String?> resolvePlayableVideoId(
  YoutubeExplode yt,
  String candidateId,
  String? title,
  String? author,
) async {
  try {
    await yt.videos.get(candidateId);
    return candidateId; // valid hai, isi ko use karo
  } catch (e) {
    log('  [id-check] "$candidateId" invalid ($e) — YT Music ka ID kharab nikla');
  }
  if (title == null) return null;
  final requery = author != null ? '$title $author' : title;
  log('  [id-check] "$requery" ke liye fresh explode search se real ID dhoondh rahe hain...');
  try {
    final results = await yt.search.getVideos(requery);
    if (results.isEmpty) return null;
    final realId = results.first.id.value;
    log('  [id-check] real ID mila: $realId');
    return realId;
  } catch (e) {
    log('  [id-check] fallback search bhi fail: $e');
    return null;
  }
}

Future<String?> _audioViaExplode(YoutubeExplode yt, String videoId) async {
  try {
    log('  [audio/explode] resolving manifest for $videoId ...');
    final manifest = await yt.videos.streams.getManifest(
      videoId,
      ytClients: [
        YoutubeApiClient.androidSdkless, // known fix for 403-on-audio-only (PoToken issue)
        YoutubeApiClient.ios,
        YoutubeApiClient.androidVr,
        YoutubeApiClient.safari,
      ],
    );

    // --- Diagnostic: har audio-only candidate ka status alag dikhao ---
    // (sirf "best bitrate" try karna gumraah kar sakta hai — kabhi lower
    // bitrate wala client kaam karta hai jab "best" wala 403 deta hai)
    final audioStreams = manifest.audioOnly;
    log('  [audio/explode] ${audioStreams.length} audio-only candidates mile, sabko check kar rahe hain:');
    String? workingUrl;
    for (final s in audioStreams) {
      final ok = await verifyPlayable(s.url.toString());
      log('    - ${s.bitrate} | ${s.container} | tag=${s.tag} -> ${ok ? "OK" : "FAIL"}');
      if (ok && workingUrl == null) workingUrl = s.url.toString();
    }

    // --- Diagnostic: ek muxed (audio+video) stream bhi check karo ---
    // Muxed streams alag client-path use karte hain — agar audio-only sab
    // FAIL ho lekin muxed OK ho, to pata chalega ki issue audio-only wale
    // PoToken-restricted streams tak hi limited hai.
    final muxed = manifest.muxed;
    if (muxed.isNotEmpty) {
      final m = muxed.first;
      final muxedOk = await verifyPlayable(m.url.toString());
      log('  [video/explode] muxed candidate: ${m.videoQuality} | ${m.container} -> ${muxedOk ? "OK" : "FAIL"}');
    } else {
      log('  [video/explode] koi muxed stream nahi mila');
    }

    if (workingUrl == null) {
      log('  [audio/explode] sab audio-only candidates FAIL (403/expired) — sambhavtah PoToken-protected video');
      return null;
    }
    log('  [audio/explode] OK, kaam karne wala stream mila!');
    return workingUrl;
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
  var videoId = args.length > 1 ? args[1] : null;

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

  // *** IMPORTANT: agar CLI se videoId nahi diya, to search ke PEHLE REAL
  // result ka ID test karo — hardcoded "hamesha available" test video
  // (Rick Astley) real Bollywood/label gaano jitna protected nahi hota,
  // isliye wo PASS hoke bhi asli gaane fail hone wala bug chhupa deta tha. ***
  String? title;
  String? author;
  if (videoId == null && results.isNotEmpty) {
    videoId = results.first['id'] as String?;
    title = results.first['title'] as String?;
    author = results.first['author'] as String?;
  }
  videoId ??= kTestVideoId;

  log('');
  log('===== STEP: videoId sanity check =====');
  final verifiedId =
      await resolvePlayableVideoId(yt, videoId, title, author) ?? videoId;

  log('');
  log('===== TEST 2: getAudioUrl("$verifiedId") — REAL search-result song =====');
  final url = await getAudioUrl(yt, verifiedId);
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
