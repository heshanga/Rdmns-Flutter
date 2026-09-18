import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdService {
  static const String _key = "rdmns_encrypted_device_token";

  static Future<String> getUniqueDeviceToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? savedToken = prefs.getString(_key);

      if (savedToken != null && savedToken.isNotEmpty) {
        return savedToken;
      }

      // Generate unique device hardware info + installation timestamp
      final deviceInfo = DeviceInfoPlugin();
      String rawDeviceData = "";

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        rawDeviceData = "AND_${androidInfo.id}_${androidInfo.model}_${androidInfo.fingerprint}";
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        rawDeviceData = "IOS_${iosInfo.identifierForVendor}_${iosInfo.model}";
      } else {
        rawDeviceData = "GENERIC_${DateTime.now().millisecondsSinceEpoch}";
      }

      final String installTimestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String rawCombined = "RDMNS_SECRET_SALT_${rawDeviceData}_$installTimestamp";

      // Encrypt / Hash combining SHA-256
      final bytes = utf8.encode(rawCombined);
      final digest = sha256.convert(bytes);
      final String encryptedToken = "RD_${digest.toString().substring(0, 16).toUpperCase()}";

      await prefs.setString(_key, encryptedToken);
      return encryptedToken;
    } catch (_) {
      return "RD_FALLBACK_DEVICE_ID";
    }
  }
}
