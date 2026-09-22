import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class AutoUpdateService {
  static const String updateJsonUrl = "https://rdmns.hesn.xyz/update.json";
  static bool _updateDialogShownInSession = false;

  static Future<void> checkForUpdates(BuildContext context) async {
    // Prevent duplicate popups during the same session
    if (_updateDialogShownInSession) return;

    try {
      final response = await http.get(Uri.parse(updateJsonUrl)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final serverVersionCode = data['versionCode'] ?? 0;
        final serverVersionName = data['versionName'] ?? '';
        final apkUrl = data['apkUrl'] ?? '';
        final releaseNotes = data['releaseNotes'] ?? 'New update available!';
        final forceUpdate = data['forceUpdate'] ?? false;

        // Dynamically fetch installed app version code
        final packageInfo = await PackageInfo.fromPlatform();
        final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 17;

        // Check if user previously dismissed this version
        final prefs = await SharedPreferences.getInstance();
        final dismissedCode = prefs.getInt('dismissed_update_version_code') ?? 0;

        // Strictly check if server version code is GREATER than installed build number
        if (serverVersionCode > currentBuildNumber &&
            serverVersionCode > dismissedCode &&
            apkUrl.isNotEmpty) {
          _updateDialogShownInSession = true;
          if (context.mounted) {
            showUpdateDialog(context, serverVersionName, serverVersionCode, apkUrl, releaseNotes, forceUpdate);
          }
        }
      }
    } catch (_) {}
  }

  static void showUpdateDialog(
    BuildContext context,
    String versionName,
    int versionCode,
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
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setInt('dismissed_update_version_code', versionCode);
                if (ctx.mounted) {
                  Navigator.of(ctx).pop();
                }
              },
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
