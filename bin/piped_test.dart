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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// -------- Yahi list SurSathi ke youtube_service.dart me bhi hai — dono
// jagah sync rakhna (instance down/naya add karna ho to dono jagah karo) --
// Static list ab sirf LAST-RESORT fallback hai (agar dynamic fetch fail ho
// jaaye). Purani 7-list ke 4 instances DNS-dead ho chuke the (nosebs.ru,
// api.piped.yt, drgns.space) aur ek bug tha (list "official" nahi thi, sirf
// jo pehle kabhi try kiya tha). Ab wiki ke current known-good instances +
// runtime par piped-instances.kavin.rocks se live list dono use hote hain.
const List<String> kStaticFallbackInstances = [
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

// Piped project khud ye endpoint maintain karta hai taaki clients hardcoded
// list par depend na hon. Ye kabhi-kabhi khud down hota hai (502) — isliye
// isse sirf "extra try" jaisa treat karo, hard dependency nahi.
const String kInstanceListUrl = 'https://piped-instances.kavin.rocks/';

const String kTestQuery = 'arijit singh';
const String kTestVideoId = 'dQw4w9WgXcQ'; // hamesha-available public video

final http.Client _client = http.Client();

void log(String msg) => stdout.writeln(msg);

// ---------------- Dynamic instance list ----------------

Future<List<String>> resolveInstances() async {
  final merged = <String>{...kStaticFallbackInstances};
  try {
    final res = await _client
        .get(Uri.parse(kInstanceListUrl))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;
      var added = 0;
      for (final entry in data) {
        // Format: [name, apiUrl, locations, cdnEnabled]
        if (entry is List && entry.length >= 2) {
          final apiUrl = entry[1] as String?;
          if (apiUrl != null && apiUrl.startsWith('http')) {
            if (merged.add(apiUrl)) added++;
          }
        }
      }
      log('  [instances] live list fetched OK, +$added naye instances');
    } else {
      log('  [instances] live list -> HTTP ${res.statusCode}, static list use karenge');
    }
  } catch (e) {
    log('  [instances] live list fetch failed ($e), static list use karenge');
  }
  final list = merged.toList();
  log('  [instances] total ${list.length} candidates race ke liye');
  return list;
}

// ---------------- Generic parallel race helper ----------------
//
// Sabhi instances ko EK SAATH try karta hai (sequential nahi). Jo pehla
// successful result deta hai wahi return hota hai; baaki ke abhi-chal-rahe
// attempts ignore kar diye jaate hain (Dart me true cancel possible nahi
// hai http client ke liye, lekin hum unke result ka wait nahi karte).
Future<T?> raceFirstSuccess<T>(
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
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }).catchError((e) {
      if (completer.isCompleted) return;
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    });
  }

  return completer.future;
}

// ---------------- Search ----------------

Future<List<Map<String, dynamic>>?> _searchOne(String base, String query) async {
  log('  [search] trying $base ...');
  try {
    final uri = Uri.parse('$base/search').replace(queryParameters: {
      'q': query,
      'filter': 'music_songs',
    });
    final res = await _client.get(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      log('  [search] $base -> HTTP ${res.statusCode}');
      return null;
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
    if (results.isEmpty) {
      log('  [search] $base -> 0 results');
      return null;
    }
    log('  [search] $base -> OK, ${results.length} results');
    return results;
  } catch (e) {
    log('  [search] $base -> error: $e');
    return null;
  }
}

Future<List<Map<String, dynamic>>> search(
    String query, List<String> instances) async {
  final result = await raceFirstSuccess<List<Map<String, dynamic>>>(
    instances,
    (base) => _searchOne(base, query),
  );
  return result ?? [];
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

Future<String?> _audioOne(String base, String videoId) async {
  log('  [audio] trying $base ...');
  try {
    final uri = Uri.parse('$base/streams/$videoId');
    final res = await _client.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      log('  [audio] $base -> HTTP ${res.statusCode}');
      return null;
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final audioStreams = (data['audioStreams'] as List?) ?? [];
    if (audioStreams.isEmpty) {
      log('  [audio] $base -> no audioStreams');
      return null;
    }
    final sorted = List<Map<String, dynamic>>.from(audioStreams)
      ..sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    final url = sorted.first['url'] as String?;
    if (url == null) {
      log('  [audio] $base -> best stream has no url');
      return null;
    }
    log('  [audio] $base -> verifying with real fetch...');
    if (!await verifyPlayable(url)) {
      log('  [audio] $base -> verify FAILED');
      return null;
    }
    log('  [audio] $base -> OK!');
    return url;
  } catch (e) {
    log('  [audio] $base -> error: $e');
    return null;
  }
}

Future<String?> getAudioUrl(String videoId, List<String> instances) async {
  return raceFirstSuccess<String>(instances, (base) => _audioOne(base, videoId));
}

// ---------------- Main ----------------

Future<void> main(List<String> args) async {
  // CLI se custom query/videoId de sakte ho:
  //   dart run bin/piped_test.dart "kishore kumar" dQw4w9WgXcQ
  final query = args.isNotEmpty ? args[0] : kTestQuery;
  final videoId = args.length > 1 ? args[1] : kTestVideoId;

  var failed = false;

  log('===== STEP 0: resolve instances (dynamic + static) =====');
  final instances = await resolveInstances();

  log('');
  log('===== TEST 1: search("$query") — parallel race across ${instances.length} instances =====');
  final results = await search(query, instances);
  if (results.isEmpty) {
    log('RESULT: FAIL — saare instances se 0 results');
    failed = true;
  } else {
    log('RESULT: PASS — ${results.length} results, pehla: ${results.first}');
  }

  log('');
  log('===== TEST 2: getAudioUrl("$videoId") — parallel race =====');
  final url = await getAudioUrl(videoId, instances);
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
