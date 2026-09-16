// bin/piped_test.dart
//
// SurSathi app ke `lib/services/youtube_service.dart` ki search + audio-URL
// resolve logic ka standalone copy — sirf testing ke liye.
//
// *** BADLAV (is version me): Piped public-instance racing HATA DIYA ***
// Wajah: 2024 se YouTube ne Piped/Invidious jaise third-party frontends ko
// datacenter-IP level par block karna shuru kar diya, aur 2026 tak ye
// crackdown itna severe ho chuka hai ki wiki ke saare "known good" Piped
// instances bhi ab dead/blocked hain (DNS fail, TLS cert broken, 502/526,
// timeout — sab ek saath). Ye koi temporary outage nahi tha, structural
// collapse hai — kitne bhi fallback instances add karo, sab isi crackdown
// se marenge kyunki sab datacenter IPs se hi host hote hain.
//
// Fix: ab hum kisi bhi third-party Piped/Invidious server par depend nahi
// karte. `youtube_explode_dart` package seedha YouTube se extract karta hai
// (NewPipe jaisi technique — reverse-engineered client APIs), isliye
// "instance down" wala poora problem hi khatam ho jaata hai.
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
// Run locally bhi ho sakta hai (agar kabhi PC mile aur Deno installed ho):
//   dart run bin/piped_test.dart

import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/solvers.dart';

const String kTestQuery = 'arijit singh';
const String kTestVideoId = 'dQw4w9WgXcQ'; // hamesha-available public video

void log(String msg) => stdout.writeln(msg);

// ---------------- Search ----------------

Future<List<Map<String, dynamic>>> search(YoutubeExplode yt, String query) async {
  log('  [search] querying YouTube directly for "$query" ...');
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
    log('  [search] OK, ${list.length} results');
    return list;
  } catch (e) {
    log('  [search] error: $e');
    return [];
  }
}

// ---------------- Verify a candidate URL is actually fetchable ----------------

Future<bool> verifyPlayable(String url) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final request =
        await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final response = await request.close().timeout(const Duration(seconds: 8));
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

Future<String?> getAudioUrl(YoutubeExplode yt, String videoId) async {
  try {
    log('  [audio] resolving manifest for $videoId ...');
    final manifest = await yt.videos.streams.getManifest(
      videoId,
      // Multiple clients try karo taaki agar ek client challenge/block ho
      // to doosra kaam kar jaaye — Piped-style instance-fallback ka
      // equivalent, lekin ab YouTube ke apne alag-alag client surfaces par.
      ytClients: [
        YoutubeApiClient.ios,
        YoutubeApiClient.androidVr,
        YoutubeApiClient.safari,
      ],
    );
    final audioStreams = manifest.audioOnly;
    if (audioStreams.isEmpty) {
      log('  [audio] no audio-only streams in manifest');
      return null;
    }
    final best = audioStreams.withHighestBitrate();
    log('  [audio] best candidate: ${best.bitrate}, verifying with real fetch...');
    if (!await verifyPlayable(best.url.toString())) {
      log('  [audio] verify FAILED');
      return null;
    }
    log('  [audio] OK!');
    return best.url.toString();
  } catch (e) {
    log('  [audio] error: $e');
    return null;
  }
}

// ---------------- Main ----------------

Future<void> main(List<String> args) async {
  // CLI se custom query/videoId de sakte ho:
  //   dart run bin/piped_test.dart "kishore kumar" dQw4w9WgXcQ
  final query = args.isNotEmpty ? args[0] : kTestQuery;
  final videoId = args.length > 1 ? args[1] : kTestVideoId;

  var failed = false;

  log('===== SETUP: init Deno JS solver (kuch clients ko cipher-challenge solve karna padta hai) =====');
  YoutubeExplode yt;
  try {
    final solver = await DenoEJSSolver.init();
    yt = YoutubeExplode(jsSolver: solver);
    log('  [setup] Deno solver ready');
  } catch (e) {
    log('  [setup] Deno solver init failed ($e) — bina solver ke aage badh rahe hain (kuch streams skip ho sakte hain)');
    yt = YoutubeExplode();
  }

  log('');
  log('===== TEST 1: search("$query") =====');
  final results = await search(yt, query);
  if (results.isEmpty) {
    log('RESULT: FAIL — 0 results');
    failed = true;
  } else {
    log('RESULT: PASS — ${results.length} results, pehla: ${results.first}');
  }

  log('');
  log('===== TEST 2: getAudioUrl("$videoId") =====');
  final url = await getAudioUrl(yt, videoId);
  if (url == null) {
    log('RESULT: FAIL — playable audio URL resolve nahi hua');
    failed = true;
  } else {
    final shown = url.length > 100 ? '${url.substring(0, 100)}...' : url;
    log('RESULT: PASS — $shown');
  }

  yt.close();

  log('');
  if (failed) {
    log('OVERALL: FAIL ❌');
    exit(1);
  } else {
    log('OVERALL: PASS ✅');
    exit(0);
  }
}
