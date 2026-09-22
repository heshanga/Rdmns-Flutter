import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'services/live_notification_service.dart';
import 'services/auto_update_service.dart';
import 'services/device_id_service.dart';

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
  InAppWebViewController? webViewController;
  double _progress = 0.0;
  bool _showOverlay = true;
  double _overlayOpacity = 1.0;
  Timer? _fallbackTimer;

  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  String _authStatusMessage = "Authenticating...";
  String _deviceToken = "";

  final String targetUrl = "https://rdmns.hesn.xyz";

  @override
  void initState() {
    super.initState();
    // Must call after first frame callback so Android FragmentActivity window has focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authenticateUser();
    });
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
        // If device has no screen lock or biometrics setup, allow access directly
        await _onAuthenticationSuccess();
        return;
      }

      final bool authenticated = await auth.authenticate(
        localizedReason: 'Please authenticate using Fingerprint, Face ID, or Screen Lock to open Rdmns app',
        options: const AuthenticationOptions(
          biometricOnly: false, // Allows Fingerprint, Face ID, PIN, Pattern, or Passcode
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

    if (!mounted) return;
    setState(() {
      _deviceToken = token;
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

    // 3.5s Safety Fallback Timer to guarantee overlay dismissal
    _fallbackTimer = Timer(const Duration(milliseconds: 3500), () {
      _dismissOverlay();
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    // UserScript Polyfill for Web Share API navigator.share & window.AndroidNotification.share
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

    // UserScript for Hardware Acceleration & Smooth CSS Transitions for Modals/Elements
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
                .modal, .dialog, .popup, .dropdown, .drawer, .sidebar, .menu, [role="dialog"], [role="menu"] {
                  -webkit-transform: translateZ(0) !important;
                  transform: translateZ(0) !important;
                  will-change: transform, opacity !important;
                  -webkit-backface-visibility: hidden !important;
                  backface-visibility: hidden !important;
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

    // UserScript for input[type="time"] crash prevention & smooth focus handling
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
          var observer = new MutationObserver(fixInputs);
          observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
      """,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );

    // If not authenticated, show secure unlock screen with prominent Unlock button
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

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Fullscreen Edge-to-Edge InAppWebView
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri(targetUrl),
              headers: {
                "X-Device-Token": _deviceToken,
              },
            ),
            initialUserScripts: UnmodifiableListView([sharePolyfillScript, gpuAcceleratePolyfillScript, timeInputCrashFixScript]),
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
              offscreenPreRaster: true,
              cacheEnabled: true,
              clearCache: false,
              verticalScrollBarEnabled: false,
              horizontalScrollBarEnabled: false,
              preferredContentMode: UserPreferredContentMode.MOBILE,
              disallowOverScroll: true,
              useHybridComposition: true,
              allowsBackForwardNavigationGestures: true,
              allowsInlineMediaPlayback: true,
              userAgent: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36 RdmnsFlutter/1.1.7 DeviceToken/$_deviceToken",
            ),
            onWebViewCreated: (controller) {
              webViewController = controller;

              // Register JavaScript Handler for Web Share API & Share buttons
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
            },
            onProgressChanged: (controller, progress) {
              _onProgressChanged(progress);
            },
            onLoadStop: (controller, url) {
              _dismissOverlay();
            },
            onReceivedError: (controller, request, error) {
              _dismissOverlay();
            },
            onCreateWindow: (controller, createWindowAction) async {
              final uri = createWindowAction.request.url;
              if (uri != null) {
                final handled = await _handleShareOrExternalUrl(uri);
                if (!handled) {
                  // Open new tab/window request directly inside the SAME WebView window!
                  await controller.loadUrl(urlRequest: createWindowAction.request);
                }
                return true;
              }
              return false;
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null) {
                final handled = await _handleShareOrExternalUrl(uri);
                if (handled) {
                  return NavigationActionPolicy.CANCEL;
                }
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),

          // Ultra-Modern Clear & Professional Loading Overlay
          if (_showOverlay)
            IgnorePointer(
              ignoring: _overlayOpacity == 0.0,
              child: AnimatedOpacity(
                opacity: _overlayOpacity,
                duration: const Duration(milliseconds: 400),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xFF0F172A), // Dark slate blue header accent
                        Color(0xFF1E293B), // Deep sleek background
                      ],
                    ),
                  ),
                  width: double.infinity,
                  height: double.infinity,
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 28),
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.15),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 30,
                            spreadRadius: 5,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Glowing Pulsing App Icon Ring
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

                          // Circular Progress & Percentage Counter Display
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

                          // Sleek Progress Line
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

                          // Professional Loading Caption
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
    );
  }
}
