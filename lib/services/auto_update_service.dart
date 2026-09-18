import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class AutoUpdateService {
  static const String updateJsonUrl = "https://rdmns.hesn.xyz/update.json";
  static const int currentVersionCode = 8; // v1.0.7

  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      final response = await http.get(Uri.parse(updateJsonUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final serverVersionCode = data['versionCode'] ?? 0;
        final serverVersionName = data['versionName'] ?? '';
        final apkUrl = data['apkUrl'] ?? '';
        final releaseNotes = data['releaseNotes'] ?? 'New update available!';
        final forceUpdate = data['forceUpdate'] ?? false;

        if (serverVersionCode > currentVersionCode && apkUrl.isNotEmpty) {
          if (context.mounted) {
            showUpdateDialog(context, serverVersionName, apkUrl, releaseNotes, forceUpdate);
          }
        }
      }
    } catch (_) {}
  }

  static void showUpdateDialog(
    BuildContext context,
    String versionName,
    String apkUrl,
    String releaseNotes,
    bool forceUpdate,
  ) {
    showDialog(
      context: context,
      barrierDismissible: !forceUpdate,
      builder: (ctx) => AlertDialog(
        title: Text("New Update Available (v$versionName)"),
        content: Text("$releaseNotes\n\nWould you like to update now?"),
        actions: [
          if (!forceUpdate)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Later"),
            ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              executeOtaUpdate(context, apkUrl);
            },
            child: const Text("Update Now"),
          ),
        ],
      ),
    );
  }

  static Future<void> executeOtaUpdate(BuildContext context, String apkUrl) async {
    final uri = Uri.parse(apkUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Could not open download link.")),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Update error: $e")),
        );
      }
    }
  }
}
