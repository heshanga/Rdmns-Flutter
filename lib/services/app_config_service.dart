import 'dart:convert';
import 'package:http/http.dart' as http;

class AppConfig {
  final String targetUrl;
  final String secretKey;

  AppConfig({
    required this.targetUrl,
    required this.secretKey,
  });
}

class AppConfigService {
  static const String configJsonUrl = "https://rdmns.hesn.xyz/config.json";
  static const String defaultTargetUrl = "https://rdmns.hesn.xyz";
  static const String defaultSecretKey = "Rdmns_App_Secure_Key_2026";

  static AppConfig? _cachedConfig;

  static Future<AppConfig> fetchRemoteConfig() async {
    if (_cachedConfig != null) return _cachedConfig!;

    try {
      final response = await http.get(Uri.parse(configJsonUrl)).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final targetUrl = data['targetUrl'] ?? defaultTargetUrl;
        final secretKey = data['secretKey'] ?? defaultSecretKey;

        _cachedConfig = AppConfig(targetUrl: targetUrl, secretKey: secretKey);
        return _cachedConfig!;
      }
    } catch (_) {}

    _cachedConfig = AppConfig(targetUrl: defaultTargetUrl, secretKey: defaultSecretKey);
    return _cachedConfig!;
  }
}
