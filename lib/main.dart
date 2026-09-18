import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'services/live_notification_service.dart';
import 'services/auto_update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enable 100% Fullscreen Immersive Mode (Auto-hide Status Bar & Navigation Bar)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // Init Notifications
  await LiveNotificationService().init();

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
  InAppWebViewController? webViewController;
  double _progress = 0.0;
  bool _showOverlay = true;
  double _overlayOpacity = 1.0;

  final String targetUrl = "https://rdmns.hesn.xyz";

  @override
  void initState() {
    super.initState();
    LiveNotificationService().startLiveStatusPolling();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AutoUpdateService.checkForUpdates(context);
    });
  }

  void _onProgressChanged(int progress) {
    setState(() {
      _progress = progress / 100.0;
    });

    if (progress == 100 && _showOverlay) {
      // Smooth 400ms fade-out animation for loading overlay
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

  @override
  Widget build(BuildContext context) {
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
              userAgent: "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Mobile Safari/537.36 RdmnsFlutter/1.0.7",
            ),
            onWebViewCreated: (controller) {
              webViewController = controller;
            },
            onProgressChanged: (controller, progress) {
              _onProgressChanged(progress);
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
            AnimatedOpacity(
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
                            value: _progress,
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
        ],
      ),
    );
  }
}
