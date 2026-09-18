import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/live_notification_service.dart';
import 'services/auto_update_service.dart';

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

  final String targetUrl = "https://rdmns.hesn.xyz";

  @override
  void initState() {
    super.initState();
    _authenticateUser();
  }

  Future<void> _authenticateUser() async {
    setState(() {
      _isAuthenticating = true;
      _authStatusMessage = "Authenticating...";
    });

    try {
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate = canAuthenticateWithBiometrics || await auth.isDeviceSupported();

      if (!canAuthenticate) {
        // If device has no screen lock or biometrics setup, allow access directly
        _onAuthenticationSuccess();
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
        _onAuthenticationSuccess();
      } else {
        if (mounted) {
          setState(() {
            _isAuthenticated = false;
            _isAuthenticating = false;
            _authStatusMessage = "Authentication Required";
          });
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _isAuthenticated = false;
          _isAuthenticating = false;
          _authStatusMessage = "Error: ${e.message ?? 'Authentication failed'}";
        });
      }
    } catch (_) {
      _onAuthenticationSuccess();
    }
  }

  void _onAuthenticationSuccess() {
    if (!mounted) return;
    setState(() {
      _isAuthenticated = true;
      _isAuthenticating = false;
    });

    try {
      LiveNotificationService().startLiveStatusPolling();
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

  @override
  Widget build(BuildContext context) {
    // If not authenticated, show secure unlock screen
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
                    Icons.lock_outline,
                    size: 72,
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
                if (!_isAuthenticating)
                  ElevatedButton.icon(
                    onPressed: _authenticateUser,
                    icon: const Icon(Icons.fingerprint, size: 24),
                    label: const Text(
                      "Unlock App",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D6EFD),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  )
                else
                  const CircularProgressIndicator(color: Color(0xFF0D6EFD)),
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
            initialUrlRequest: URLRequest(url: WebUri(targetUrl)),
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
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
              userAgent: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36 RdmnsFlutter/1.0.8",
            ),
            onWebViewCreated: (controller) {
              webViewController = controller;
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
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final uri = navigationAction.request.url;
              if (uri != null) {
                final scheme = uri.scheme.toLowerCase();
                if (['whatsapp', 'tel', 'mailto', 'tg', 'maps', 'intent'].contains(scheme)) {
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }
                }
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),

          // Sleek Animated Loading Overlay with Percentage Counter
          if (_showOverlay)
            IgnorePointer(
              ignoring: _overlayOpacity == 0.0,
              child: AnimatedOpacity(
                opacity: _overlayOpacity,
                duration: const Duration(milliseconds: 400),
                child: Container(
                  color: Colors.white,
                  width: double.infinity,
                  height: double.infinity,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.language,
                        size: 80,
                        color: Color(0xFF0D6EFD),
                      ),
                      const SizedBox(height: 32),

                      // Circular Progress & Percentage Display
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 130,
                            height: 130,
                            child: CircularProgressIndicator(
                              value: _progress > 0 ? _progress : null,
                              strokeWidth: 8,
                              backgroundColor: Colors.grey.shade200,
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF0D6EFD)),
                            ),
                          ),
                          Text(
                            "${(_progress * 100).toInt()}%",
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0D6EFD),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "Loading Rdmns...",
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
