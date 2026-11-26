// RDMNS AI · voice bridge – gives the AI page the phone's own speech-to-text and voice.
//
// Adapted from rdmns_ai_flutter/lib/ai/rdmns_voice_bridge.dart to flutter_inappwebview,
// which the rest of the app already uses. The JavaScript protocol is unchanged:
//   page → app : RDMNSApp.postMessage(JSON) with
//                {"cmd":"hello"} {"cmd":"listen","lang":"si-LK"} {"cmd":"stop"}
//                {"cmd":"speak","text":"…","lang":"si-LK"} {"cmd":"stopSpeak"}
//   app → page : rdmnsVoice.ready() · rdmnsVoice.result(text, isFinal) · rdmnsVoice.error(code)
//                rdmnsVoice.end() · rdmnsVoice.speakEnd()
//
// flutter_inappwebview has no webview_flutter-style JavaScriptChannel, so [channelShim]
// defines window.RDMNSApp.postMessage at document start and forwards to the
// "RDMNSApp" JavaScript handler registered by [attach].

import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class RdmnsVoiceBridge {
  RdmnsVoiceBridge({this.onMicBlocked});

  /// Called when the microphone is permanently denied – show a SnackBar with "Open settings".
  final void Function()? onMicBlocked;

  InAppWebViewController? _controller;
  final stt.SpeechToText _stt = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _sttReady = false;
  bool _listening = false;
  bool _speaking = false;
  bool _ttsReady = false;

  /// Injected at document start in the AI tab only: window.RDMNSApp.postMessage(...)
  static const String channelShim = r'''
(function(){
  if (window.RDMNSApp) return;
  var queue = [];
  function send(m) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('RDMNSApp', String(m));
      return true;
    }
    return false;
  }
  window.RDMNSApp = { postMessage: function(m){ if (!send(m)) queue.push(m); } };
  window.addEventListener('flutterInAppWebViewPlatformReady', function(){
    while (queue.length) send(queue.shift());
  });
})();
''';

  /// Call from onWebViewCreated.
  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'RDMNSApp',
      callback: (args) {
        if (args.isNotEmpty) _onMessage(args.first);
        return null;
      },
    );
    if (!_ttsReady) {
      _ttsReady = true;
      _tts.setCompletionHandler(_speakEnd);
      _tts.setCancelHandler(_speakEnd);
      _tts.setErrorHandler((_) => _speakEnd());
      _tts.awaitSpeakCompletion(false);
    }
  }

  /// Call from onLoadStop so the page knows native voice is here.
  Future<void> announce() => _js('window.rdmnsVoice && window.rdmnsVoice.ready()');

  /// Call when the tab is hidden, the app goes to the background, or on dispose.
  Future<void> stopAll() async {
    try {
      if (_listening) await _stt.cancel();
    } catch (_) {}
    _listening = false;
    try {
      await _tts.stop();
    } catch (_) {}
  }

  void dispose() => stopAll();

  // ------------------------------------------------------------------

  void _speakEnd() {
    if (!_speaking) return;
    _speaking = false;
    _js('window.rdmnsVoice && window.rdmnsVoice.speakEnd()');
  }

  Future<void> _js(String code) async {
    try {
      await _controller?.evaluateJavascript(source: code);
    } catch (_) {}
  }

  String _q(String s) => jsonEncode(s); // safe for Sinhala text and quotes

  Future<void> _onMessage(dynamic raw) async {
    Map<String, dynamic> m;
    try {
      m = raw is Map ? Map<String, dynamic>.from(raw) : jsonDecode(raw.toString()) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['cmd']) {
      case 'hello':
        await announce();
        break;
      case 'listen':
        await _listen((m['lang'] as String?) ?? 'si-LK');
        break;
      case 'stop':
        if (_listening) await _stt.stop(); // final result + end() still follow
        break;
      case 'speak':
        await _speak((m['text'] as String?) ?? '', (m['lang'] as String?) ?? 'si-LK');
        break;
      case 'stopSpeak':
        await _tts.stop();
        _speakEnd();
        break;
    }
  }

  Future<void> _speak(String text, String lang) async {
    if (_listening) {
      await _stt.cancel();
      _listening = false;
    }
    _speaking = true;
    final ok = await _tts.isLanguageAvailable(lang);
    if (ok != true || text.trim().isEmpty) {
      _speakEnd(); // no voice for this language on the phone → the page shows the text only
      return;
    }
    await _tts.setLanguage(lang);
    await _tts.setSpeechRate(lang.startsWith('si') ? 0.45 : 0.5);
    await _tts.setPitch(1.0);
    final r = await _tts.speak(text);
    if (r != 1) _speakEnd();
  }

  Future<void> _listen(String lang) async {
    var perm = await Permission.microphone.status;
    if (!perm.isGranted) perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      if (perm.isPermanentlyDenied) onMicBlocked?.call();
      await _js('window.rdmnsVoice && window.rdmnsVoice.error("not-allowed")');
      return;
    }
    if (!_sttReady) {
      _sttReady = await _stt.initialize(onError: _onSttError, onStatus: _onStatus);
      if (!_sttReady) {
        await _js('window.rdmnsVoice && window.rdmnsVoice.error("unavailable")');
        return;
      }
    }
    await _tts.stop();
    final locale = await _locale(lang);
    _listening = true;
    await _stt.listen(
      localeId: locale,
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 2),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.search,
      ),
      onResult: (r) => _js('window.rdmnsVoice && window.rdmnsVoice.result(${_q(r.recognizedWords)}, ${r.finalResult})'),
    );
  }

  /// "si-LK" → "si_LK"; English falls back en_GB → en_US → en_IN.
  Future<String?> _locale(String lang) async {
    final want = lang.replaceAll('-', '_');
    final have = (await _stt.locales()).map((l) => l.localeId).toSet();
    if (have.contains(want)) return want;
    if (want.startsWith('en')) {
      for (final l in ['en_GB', 'en_US', 'en_IN']) {
        if (have.contains(l)) return l;
      }
    }
    return want; // let the recogniser try (Google app often supports si_LK without listing it)
  }

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') && _listening) {
      _listening = false;
      _js('window.rdmnsVoice && window.rdmnsVoice.end()');
    }
  }

  void _onSttError(SpeechRecognitionError e) {
    _listening = false;
    final m = e.errorMsg;
    final code = (m.contains('no_match') || m.contains('speech_timeout'))
        ? 'no-speech'
        : (m.contains('permission') || m.contains('insufficient_permissions'))
            ? 'not-allowed'
            : m;
    _js('window.rdmnsVoice && window.rdmnsVoice.error(${_q(code)})');
    _js('window.rdmnsVoice && window.rdmnsVoice.end()');
  }
}
