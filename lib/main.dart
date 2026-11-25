import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:ui' as ui;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:local_auth/local_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'services/live_notification_service.dart';
import 'services/auto_update_service.dart';
import 'services/device_id_service.dart';
import 'services/app_config_service.dart';
import 'services/dynamic_token_service.dart';

// ---------------------------------------------------------------------------
// The app only opens these four RDMNS pages (one tab each).
// ---------------------------------------------------------------------------
const String kRdmnsHost = 'rdmns.hesn.xyz';

class RdmnsTab {
  final String url;
  final String path;
  final IconData icon;
  final IconData activeIcon;
  const RdmnsTab(this.url, this.path, this.icon, this.activeIcon);
}

const List<RdmnsTab> kTabs = [
  RdmnsTab('https://rdmns.hesn.xyz', '', Icons.home_outlined, Icons.home_rounded),
  RdmnsTab('https://rdmns.hesn.xyz/v1map', '/v1map', Icons.map_outlined, Icons.map_rounded),
  RdmnsTab('https://rdmns.hesn.xyz/v1radar', '/v1radar', Icons.track_changes, Icons.track_changes),
  RdmnsTab('https://rdmns.hesn.xyz/v1timetable', '/v1timetable', Icons.schedule_outlined, Icons.schedule_rounded),
];

const Map<String, List<String>> kTabLabels = {
  'en': ['Home', 'Map', 'Radar', 'Timetable'],
  'si': ['මුල් පිටුව', 'සිතියම', 'රේඩාර්', 'කාලසටහන'],
  'ta': ['முகப்பு', 'வரைபடம்', 'ரேடார்', 'அட்டவணை'],
};

const Map<String, List<String>> kNetLabels = {
  'en': ['No internet connection', 'Back online'],
  'si': ['අන්තර්ජාල සම්බන්ධතාවය නැත', 'නැවත සම්බන්ධ විය'],
  'ta': ['இணைய இணைப்பு இல்லை', 'மீண்டும் இணைக்கப்பட்டது'],
};

/// Reports scrolling of any element (pages scroll inside their own containers)
/// so the tab bar can hide while reading and come back on scroll-up.
const String kNavScrollJs = r'''
(function(){
  if (window.__rdmnsNav) return; window.__rdmnsNav = 1;
  var last = new WeakMap(), acc = 0;
  document.addEventListener('scroll', function(e){
    var t = e.target;
    var el = (t === document || t === document.documentElement || t === document.body)
             ? (document.scrollingElement || document.documentElement) : t;
    if (!el || el.scrollHeight - el.clientHeight < 80) return;
    var y = el.scrollTop, p = last.has(el) ? last.get(el) : y;
    last.set(el, y);
    var dy = y - p;
    if ((dy > 0) !== (acc > 0)) acc = 0;
    acc += dy;
    if (Math.abs(acc) > 12 || y < 24) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('NavScroll', Math.round(acc), Math.round(y));
      }
      acc = 0;
    }
  }, {capture: true, passive: true});
})();
''';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable 100% Fullscreen Immersive Mode (Auto-hide Status Bar & Navigation Bar)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Init Notifications with Safety Catch
  try {
    await LiveNotificationService().init();
  } catch (_) {}

  runApp(const RdmnsApp());
}

class RdmnsApp extends StatelessWidget {
  const RdmnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rdmns',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D6EFD)),
        useMaterial3: true,
      ),
      home: const MainWebViewScreen(),
    );
  }
}

class MainWebViewScreen extends StatefulWidget {
  const MainWebViewScreen({super.key});

  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen> {
  final LocalAuthentication auth = LocalAuthentication();
  InAppWebViewController? get webViewController => _controllers[_current];

  // Tabs
  int _current = 0;
  final List<InAppWebViewController?> _controllers = List<InAppWebViewController?>.filled(kTabs.length, null);
  final Set<int> _created = {0};
  final List<double> _tabProgress = List<double>.filled(kTabs.length, 0);
  final Set<int> _errored = {};

  // Auto-hiding tab bar
  bool _navShown = true;
  bool _navCollapsed = false;
  Timer? _navTimer;

  // Connection banner
  bool _offline = false;
  bool _bannerVisible = false;
  Timer? _netTimer;
  Timer? _bannerTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  String get _lang {
    final code = ui.PlatformDispatcher.instance.locale.languageCode;
    return kTabLabels.containsKey(code) ? code : 'en';
  }
  double _progress = 0.0;
  bool _showOverlay = true;
  double _overlayOpacity = 1.0;
  Timer? _fallbackTimer;

  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  String _authStatusMessage = "Authenticating...";
  String _deviceToken = "";
  DateTime? _lastBackPressTime;

  String targetUrl = AppConfigService.defaultTargetUrl;
  String secretKey = AppConfigService.defaultSecretKey;

  Future<bool> _handleBackPress() async {
    if (webViewController != null && await webViewController!.canGoBack()) {
      await webViewController!.goBack();
      return false;
    }

    if (_current != 0) {
      _selectTab(0);
      return false;
    }

    final now = DateTime.now();
    if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Press back again to exit Rdmns app"),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authenticateUser();
    });

    Connectivity().checkConnectivity().then((r) {
      if (_isOffline(r)) _setOffline(true);
    }).catchError((_) {});
    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
  }

  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;

    setState(() {
      _isAuthenticating = true;
      _authStatusMessage = "Please verify your Fingerprint, Face ID, or PIN...";
    });

    try {
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool isSupported = await auth.isDeviceSupported();
      final bool canAuthenticate = canAuthenticateWithBiometrics || isSupported;

      if (!canAuthenticate) {
        await _onAuthenticationSuccess();
        return;
      }

      final bool authenticated = await auth.authenticate(
        localizedReason: 'Please authenticate using Fingerprint, Face ID, or Screen Lock to open Rdmns app',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );

      if (authenticated) {
        await _onAuthenticationSuccess();
      } else {
        if (mounted) {
          setState(() {
            _isAuthenticated = false;
            _isAuthenticating = false;
            _authStatusMessage = "Authentication Cancelled or Failed";
          });
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _isAuthenticated = false;
          _isAuthenticating = false;
          _authStatusMessage = "Auth Error: ${e.message ?? 'Authentication failed'}";
        });
      }
    } catch (_) {
      await _onAuthenticationSuccess();
    }
  }

  Future<void> _onAuthenticationSuccess() async {
    final String token = await DeviceIdService.getUniqueDeviceToken();
    final config = await AppConfigService.fetchRemoteConfig();

    if (!mounted) return;
    setState(() {
      _deviceToken = token;
      targetUrl = config.targetUrl;
      secretKey = config.secretKey;
      _isAuthenticated = true;
      _isAuthenticating = false;
    });

    try {
      LiveNotificationService().startLiveStatusPolling(userId: token);
    } catch (_) {}

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        AutoUpdateService.checkForUpdates(context);
      } catch (_) {}
    });

    _fallbackTimer = Timer(const Duration(milliseconds: 3500), () {
      _dismissOverlay();
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _navTimer?.cancel();
    _netTimer?.cancel();
    _bannerTimer?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  void _dismissOverlay() {
    if (_showOverlay && mounted) {
      setState(() {
        _overlayOpacity = 0.0;
      });
      Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          setState(() {
            _showOverlay = false;
          });
        }
      });
    }
  }

  void _onProgressChanged(int progress) {
    if (mounted) {
      setState(() {
        _progress = progress / 100.0;
      });
    }

    if (progress >= 80) {
      _dismissOverlay();
    }
  }

  Future<bool> _handleShareOrExternalUrl(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    final urlString = uri.toString();

    final isShareScheme = ['whatsapp', 'tel', 'mailto', 'tg', 'maps', 'intent', 'sms', 'fb-messenger'].contains(scheme);
    final isShareUrl = urlString.contains('facebook.com/sharer') ||
        urlString.contains('twitter.com/intent') ||
        urlString.contains('api.whatsapp.com/send') ||
        urlString.contains('whatsapp://send') ||
        urlString.contains('t.me/share') ||
        urlString.contains('telegram.me/share') ||
        urlString.contains('share=true') ||
        urlString.contains('action=share');

    if (isShareScheme || isShareUrl) {
      if (await canLaunchUrl(uri)) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return true;
        } catch (_) {}
      }

      String textToShare = uri.queryParameters['text'] ??
          uri.queryParameters['url'] ??
          uri.queryParameters['u'] ??
          urlString;

      await Share.share(textToShare);
      return true;
    }
    return false;
  }

  // ------------------------------------------------------------------ tabs

  bool _isInternalHost(String host) {
    final h = host.toLowerCase();
    return h == kRdmnsHost || h == 'rdmns.lk' || h.endsWith('.rdmns.lk');
  }

  /// Index of the tab whose start page is exactly [uri], else null.
  int? _tabForUrl(Uri uri) {
    if (uri.host.toLowerCase() != kRdmnsHost || uri.query.isNotEmpty) return null;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    for (var i = 0; i < kTabs.length; i++) {
      if (kTabs[i].path == path) return i;
    }
    return null;
  }

  URLRequest _tabRequest(int i) => URLRequest(
        url: WebUri(kTabs[i].url),
        headers: DynamicTokenService.buildSecureHeaders(_deviceToken, secretKey: secretKey),
      );

  Future<void> _selectTab(int i) async {
    HapticFeedback.selectionClick();
    if (i == _current) {
      // Tapping the open tab: back to its start page, or reload if already there.
      final c = _controllers[i];
      if (c == null) return;
      final url = await c.getUrl();
      if (url != null && _tabForUrl(url) == i) {
        await c.reload();
      } else {
        await c.loadUrl(urlRequest: _tabRequest(i));
      }
      return;
    }
    final previous = _current;
    setState(() {
      _current = i;
      _created.add(i);
    });
    if (Platform.isAndroid) {
      // Hidden tabs stop drawing so the visible one gets the full GPU/CPU.
      _controllers[previous]?.pause().catchError((_) {});
      _controllers[i]?.resume().catchError((_) {});
    }
    _showNav();
  }

  Future<void> _openExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// Keeps navigation on the RDMNS site. A link to one of the four start pages
  /// switches to that tab; any other website opens outside the app.
  Future<NavigationActionPolicy> _routeUrl(int tab, Uri uri, bool mainFrame) async {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      if (!mainFrame) return NavigationActionPolicy.ALLOW;
      if (_isInternalHost(uri.host)) {
        final t = _tabForUrl(uri);
        if (t != null && t != tab) {
          _selectTab(t);
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      }
      await _openExternal(uri);
      return NavigationActionPolicy.CANCEL;
    }
    if (const ['about', 'data', 'blob', 'javascript'].contains(scheme)) {
      return NavigationActionPolicy.ALLOW;
    }
    await _openExternal(uri);
    return NavigationActionPolicy.CANCEL;
  }

  // ------------------------------------------------------------------ tab bar

  void _hideNav() {
    if (!_navShown || !mounted) return;
    _navTimer?.cancel();
    setState(() => _navShown = false);
    _navTimer = Timer(const Duration(milliseconds: 230), () {
      if (mounted && !_navShown) setState(() => _navCollapsed = true);
    });
  }

  void _showNav() {
    if (_navShown || !mounted) return;
    _navTimer?.cancel();
    if (_navCollapsed) {
      setState(() => _navCollapsed = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _navShown = true);
      });
    } else {
      setState(() => _navShown = true);
    }
  }

  Widget _buildTabBar(bool dark) {
    final accent = dark ? const Color(0xFFFF5A71) : const Color(0xFF9B1B31);
    final inactive = dark ? const Color(0xFF8E8E96) : const Color(0xFF8A8A93);
    final bg = dark ? const Color(0xFF121214) : const Color(0xFFF9F9FB);
    final line = dark ? const Color(0x8C545458) : const Color(0x213C3C43);
    final labels = kTabLabels[_lang]!;
    return AnimatedSlide(
      offset: _navShown ? Offset.zero : const Offset(0, 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          border: Border(top: BorderSide(color: line, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: List.generate(kTabs.length, (i) {
                final selected = i == _current;
                final color = selected ? accent : inactive;
                return Expanded(
                  child: InkWell(
                    onTap: () => _selectTab(i),
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(selected ? kTabs[i].activeIcon : kTabs[i].icon, color: color, size: 24),
                        const SizedBox(height: 3),
                        Text(
                          labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ connection

  bool _isOffline(List<ConnectivityResult> r) =>
      r.isEmpty || r.every((e) => e == ConnectivityResult.none);

  void _onConnectivityChanged(List<ConnectivityResult> r) {
    final off = _isOffline(r);
    _netTimer?.cancel();
    // Small wait so a Wi-Fi -> mobile data hand-over doesn't flash the banner.
    _netTimer = Timer(Duration(milliseconds: off ? 1200 : 300), () => _setOffline(off));
  }

  void _setOffline(bool off) {
    if (!mounted || off == _offline) return;
    _bannerTimer?.cancel();
    setState(() {
      _offline = off;
      _bannerVisible = true;
    });
    if (off) {
      HapticFeedback.heavyImpact();
    } else {
      _bannerTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted && !_offline) setState(() => _bannerVisible = false);
      });
      for (final i in _errored.toList()) {
        _controllers[i]?.reload();
      }
    }
  }

  Widget _buildNetBanner() {
    final text = kNetLabels[_lang]![_offline ? 0 : 1];
    return IgnorePointer(
      child: Center(
        child: AnimatedSlide(
          offset: _bannerVisible ? Offset.zero : const Offset(0, -2),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: _bannerVisible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: _offline ? const Color(0xFFD93A3A) : const Color(0xFF1F8A43),
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_offline ? Icons.cloud_off_rounded : Icons.check_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 7),
                  Text(
                    text,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ web views

  Widget _buildWebView(int i, List<UserScript> scripts) {
    return InAppWebView(
      key: ValueKey('rdmns_tab_$i'),
      initialUrlRequest: _tabRequest(i),
      initialUserScripts: UnmodifiableListView(scripts),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: false,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        hardwareAcceleration: true,
        offscreenPreRaster: false,
        cacheEnabled: true,
        clearCache: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        disallowOverScroll: true,
        useHybridComposition: true,
        allowsBackForwardNavigationGestures: true,
        allowsInlineMediaPlayback: true,
        geolocationEnabled: true,
        userAgent: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36 RdmnsFlutter/1.2.3 DeviceToken/$_deviceToken",
      ),
      onWebViewCreated: (controller) {
        _controllers[i] = controller;

        controller.addJavaScriptHandler(
          handlerName: 'NativeShare',
          callback: (args) {
            if (args.isNotEmpty) {
              final text = args[0].toString();
              final url = args.length > 1 ? args[1].toString() : '';
              final subject = args.length > 2 ? args[2].toString() : '';

              final shareText = text.isNotEmpty ? text : url;
              if (shareText.isNotEmpty) {
                Share.share(shareText, subject: subject.isNotEmpty ? subject : null);
              }
            }
          },
        );

        controller.addJavaScriptHandler(
          handlerName: 'NavScroll',
          callback: (args) {
            if (i != _current || args.length < 2) return null;
            final dy = (args[0] as num).toDouble();
            final y = (args[1] as num).toDouble();
            if (y < 24 || dy < 0) {
              _showNav();
            } else {
              _hideNav();
            }
            return null;
          },
        );
      },
      onProgressChanged: (controller, progress) {
        if (i == 0) _onProgressChanged(progress);
        _tabProgress[i] = progress / 100.0;
        if (i == _current && mounted) setState(() {});
      },
      onLoadStart: (controller, url) {
        _errored.remove(i);
        if (i == _current) _showNav();
      },
      onLoadStop: (controller, url) {
        if (i == 0) _dismissOverlay();
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame ?? true) _errored.add(i);
        if (i == 0) _dismissOverlay();
      },
      onGeolocationPermissionsShowPrompt: (controller, origin) async {
        final status = await Permission.locationWhenInUse.request();
        final ok = status.isGranted || status.isLimited;
        return GeolocationPermissionShowPromptResponse(origin: origin, allow: ok, retain: ok);
      },
      onCreateWindow: (controller, createWindowAction) async {
        final uri = createWindowAction.request.url;
        if (uri != null) {
          final handled = await _handleShareOrExternalUrl(uri);
          if (!handled) {
            final policy = await _routeUrl(i, uri, true);
            if (policy == NavigationActionPolicy.ALLOW) {
              await controller.loadUrl(urlRequest: createWindowAction.request);
            }
          }
          return true;
        }
        return false;
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;
        final handled = await _handleShareOrExternalUrl(uri);
        if (handled) {
          return NavigationActionPolicy.CANCEL;
        }
        return _routeUrl(i, uri, navigationAction.isForMainFrame);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final UserScript navScrollScript = UserScript(
      source: kNavScrollJs,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
    );

    final UserScript sharePolyfillScript = UserScript(
      source: """
        (function() {
          if (!window.navigator.share) {
            window.navigator.share = function(data) {
              return new Promise(function(resolve, reject) {
                try {
                  var text = '';
                  if (data) {
                    if (data.title) text += data.title + '\\n';
                    if (data.text) text += data.text + '\\n';
                    if (data.url) text += data.url;
                  }
                  text = text.trim();
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('NativeShare', text, data ? (data.url || '') : '', data ? (data.title || '') : '');
                  } else if (window.AndroidNotification && window.AndroidNotification.share) {
                    window.AndroidNotification.share(text);
                  }
                  resolve();
                } catch(e) {
                  reject(e);
                }
              });
            };
          }

          if (!window.AndroidNotification) window.AndroidNotification = {};
          window.AndroidNotification.share = function(text) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('NativeShare', text, '', '');
            }
          };
        })();
      """,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );

    final UserScript gpuAcceleratePolyfillScript = UserScript(
      source: """
        (function() {
          var injectSmoothCSS = function() {
            if (document.head && !document.getElementById('smooth-gpu-css')) {
              var style = document.createElement('style');
              style.id = 'smooth-gpu-css';
              style.type = 'text/css';
              style.innerHTML = `
                * {
                  -webkit-tap-highlight-color: transparent !important;
                }
              `;
              document.head.appendChild(style);
            }
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectSmoothCSS);
          } else {
            injectSmoothCSS();
          }
        })();
      """,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );

    final UserScript timeInputCrashFixScript = UserScript(
      source: """
        (function() {
          var fixInputs = function() {
            var timeInputs = document.querySelectorAll('input[type="time"], input[type="date"], input[type="datetime-local"]');
            timeInputs.forEach(function(el) {
              if (!el.dataset.timeCrashFixed) {
                el.dataset.timeCrashFixed = "true";
                el.addEventListener('focus', function(e) { e.stopPropagation(); }, { passive: true });
                el.addEventListener('change', function(e) { e.stopPropagation(); }, { passive: true });
              }
            });
          };
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', fixInputs);
          } else {
            fixInputs();
          }
          var pending = false;
          var observer = new MutationObserver(function() {
            if (pending) return;
            pending = true;
            setTimeout(function() { pending = false; fixInputs(); }, 400);
          });
          observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
      """,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );

    if (!_isAuthenticated) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D6EFD).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.fingerprint,
                    size: 80,
                    color: Color(0xFF0D6EFD),
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  "Rdmns App Locked",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _authStatusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 40),
                ElevatedButton.icon(
                  onPressed: _authenticateUser,
                  icon: const Icon(Icons.lock_open, size: 24),
                  label: Text(
                    _isAuthenticating ? "Verifying..." : "Unlock App",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D6EFD),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final bool dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bool keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final double tabProgress = _tabProgress[_current];
    final List<UserScript> scripts = [sharePolyfillScript, gpuAcceleratePolyfillScript, timeInputCrashFixScript, navScrollScript];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _handleBackPress();
        if (shouldPop && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: dark ? Colors.black : const Color(0xFFF2F2F7),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      // One web view per tab, kept alive so switching tabs doesn't reload.
                      Positioned.fill(
                        child: IndexedStack(
                          index: _current,
                          children: List.generate(
                            kTabs.length,
                            (i) => _created.contains(i) ? _buildWebView(i, scripts) : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      if (!_showOverlay && tabProgress > 0 && tabProgress < 1)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: tabProgress,
                            minHeight: 2,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              dark ? const Color(0xFFFF5A71) : const Color(0xFF9B1B31),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!_navCollapsed && !keyboardOpen) _buildTabBar(dark),
              ],
            ),

            Positioned(
              top: MediaQuery.paddingOf(context).top + 10,
              left: 0,
              right: 0,
              child: _buildNetBanner(),
            ),

            if (_showOverlay)
              IgnorePointer(
                ignoring: _overlayOpacity == 0.0,
                child: AnimatedOpacity(
                  opacity: _overlayOpacity,
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    color: const Color(0xFF0F172A),
                    width: double.infinity,
                    height: double.infinity,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.5),
                              blurRadius: 35,
                              offset: const Offset(0, 15),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    const Color(0xFF0D6EFD).withOpacity(0.3),
                                    const Color(0xFF0D6EFD).withOpacity(0.05),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF0D6EFD).withOpacity(0.4),
                                    blurRadius: 25,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.language,
                                size: 64,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                            const SizedBox(height: 32),
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 110,
                                  height: 110,
                                  child: CircularProgressIndicator(
                                    value: _progress > 0 ? _progress : null,
                                    strokeWidth: 6,
                                    backgroundColor: Colors.white10,
                                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                                  ),
                                ),
                                Text(
                                  "${(_progress * 100).toInt()}%",
                                  style: const TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 28),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 180,
                                height: 4,
                                child: LinearProgressIndicator(
                                  value: _progress > 0 ? _progress : null,
                                  backgroundColor: Colors.white10,
                                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0D6EFD)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              "Loading Rdmns App...",
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
