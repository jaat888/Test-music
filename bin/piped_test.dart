// bin/piped_test.dart
//
// SurSathi app ke `lib/services/youtube_service.dart` ki Piped-based
// search + getAudioUrl logic ka standalone copy — sirf testing ke liye.
//
// Kyu alag repo/file: SurSathi Flutter app hai, uski APK build karke test
// karne me 2-3 minute lagte hain har chhoti si logic change ke liye. Ye
// script sirf plain Dart hai (koi Flutter/Android build nahi), isliye
// GitHub Actions pe ~15-20 second me chal jaati hai.
//
// WORKFLOW:
//   1. Yahan (ya SurSathi ke youtube_service.dart me) jo bhi logic change
//      karni ho, dono jagah karo (isliye header me har baar reminder hai).
//   2. Ye poora folder zip karke is (alag) repo me push karo — jaisa
//      SurSathi wale repo me zip-upload se hota hai, extract.yml wahi
//      pattern follow karta hai.
//   3. Actions tab me "Test Piped Logic" run dekho — 15-20 sec me PASS/FAIL
//      pata chal jaayega.
//   4. Jab yahan PASS ho jaaye, TABHI wahi (verified) logic SurSathi ke
//      youtube_service.dart me daal ke asli APK build karo.
//
// Run locally bhi ho sakta hai (agar kabhi PC mile): `dart run bin/piped_test.dart`

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// -------- Yahi list SurSathi ke youtube_service.dart me bhi hai — dono
// jagah sync rakhna (instance down/naya add karna ho to dono jagah karo) --
const List<String> kInstances = [
  'https://pipedapi.kavin.rocks',
  'https://pipedapi.leptons.xyz',
  'https://pipedapi.nosebs.ru',
  'https://pipedapi-libre.kavin.rocks',
  'https://pipedapi.adminforge.de',
  'https://api.piped.yt',
  'https://pipedapi.drgns.space',
];

const String kTestQuery = 'arijit singh';
const String kTestVideoId = 'dQw4w9WgXcQ'; // hamesha-available public video

final http.Client _client = http.Client();

void log(String msg) => stdout.writeln(msg);

// ---------------- Search ----------------

Future<List<Map<String, dynamic>>> search(String query) async {
  for (final base in kInstances) {
    log('  [search] trying $base ...');
    try {
      final uri = Uri.parse('$base/search').replace(queryParameters: {
        'q': query,
        'filter': 'music_songs',
      });
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        log('  [search] $base -> HTTP ${res.statusCode}, trying next');
        continue;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];
      final results = <Map<String, dynamic>>[];
      for (final it in items) {
        final map = it as Map<String, dynamic>;
        final rawUrl = map['url'] as String?;
        if (rawUrl == null) continue;
        final id = Uri.parse(rawUrl).queryParameters['v'];
        if (id == null || id.isEmpty) continue;
        results.add({
          'id': id,
          'title': map['title'],
          'author': map['uploaderName'],
          'duration': map['duration'],
        });
      }
      if (results.isNotEmpty) {
        log('  [search] $base -> OK, ${results.length} results');
        return results;
      }
      log('  [search] $base -> 0 results, trying next');
    } catch (e) {
      log('  [search] $base -> error: $e, trying next');
      continue;
    }
  }
  return [];
}

// ---------------- Verify a candidate URL is actually fetchable ----------------

Future<bool> verifyPlayable(String url) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    final request =
        await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 6));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final response = await request.close().timeout(const Duration(seconds: 6));
    await response.drain<List<int>>();
    return response.statusCode == 200 || response.statusCode == 206;
  } catch (e) {
    log('  [verify] failed: $e');
    return false;
  } finally {
    client?.close(force: true);
  }
}

// ---------------- Audio URL resolve ----------------

Future<String?> getAudioUrl(String videoId) async {
  for (final base in kInstances) {
    log('  [audio] trying $base ...');
    try {
      final uri = Uri.parse('$base/streams/$videoId');
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        log('  [audio] $base -> HTTP ${res.statusCode}, trying next');
        continue;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final audioStreams = (data['audioStreams'] as List?) ?? [];
      if (audioStreams.isEmpty) {
        log('  [audio] $base -> no audioStreams, trying next');
        continue;
      }
      final sorted = List<Map<String, dynamic>>.from(audioStreams)
        ..sort((a, b) =>
            ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
      final url = sorted.first['url'] as String?;
      if (url == null) {
        log('  [audio] $base -> best stream has no url, trying next');
        continue;
      }
      log('  [audio] $base -> verifying with real fetch...');
      if (!await verifyPlayable(url)) {
        log('  [audio] $base -> verify FAILED, trying next');
        continue;
      }
      log('  [audio] $base -> OK!');
      return url;
    } catch (e) {
      log('  [audio] $base -> error: $e, trying next');
      continue;
    }
  }
  return null;
}

// ---------------- Main ----------------

Future<void> main(List<String> args) async {
  // CLI se custom query/videoId de sakte ho:
  //   dart run bin/piped_test.dart "kishore kumar" dQw4w9WgXcQ
  final query = args.isNotEmpty ? args[0] : kTestQuery;
  final videoId = args.length > 1 ? args[1] : kTestVideoId;

  var failed = false;

  log('===== TEST 1: search("$query") =====');
  final results = await search(query);
  if (results.isEmpty) {
    log('RESULT: FAIL — saare instances se 0 results');
    failed = true;
  } else {
    log('RESULT: PASS — ${results.length} results, pehla: ${results.first}');
  }

  log('');
  log('===== TEST 2: getAudioUrl("$videoId") =====');
  final url = await getAudioUrl(videoId);
  if (url == null) {
    log('RESULT: FAIL — koi bhi instance se playable URL nahi mila');
    failed = true;
  } else {
    final shown = url.length > 100 ? '${url.substring(0, 100)}...' : url;
    log('RESULT: PASS — $shown');
  }

  _client.close();

  log('');
  if (failed) {
    log('OVERALL: FAIL ❌');
    exit(1);
  } else {
    log('OVERALL: PASS ✅');
    exit(0);
  }
}
