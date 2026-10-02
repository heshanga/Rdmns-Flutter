import 'dart:convert';
import 'package:crypto/crypto.dart';

class DynamicTokenService {
  static const String defaultSecretKey = "Rdmns_App_Secure_Key_2026";

  /// Gets the current 60-second time slot integer
  static int getCurrentTimeSlot() {
    return (DateTime.now().millisecondsSinceEpoch / 60000).floor();
  }

  /// Generates a 60-second time-synchronized SHA-256 security token
  static String generateDynamicToken({
    required String deviceToken,
    String secretKey = defaultSecretKey,
    int? timeSlot,
  }) {
    final slot = timeSlot ?? getCurrentTimeSlot();
    final rawString = "${secretKey}_${slot}_$deviceToken";
    final bytes = utf8.encode(rawString);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16).toUpperCase();
  }

  /// Builds a secure target URL with dynamic token query parameters
  static String buildSecureUrl(String baseUrl, String deviceToken, {String secretKey = defaultSecretKey}) {
    final slot = getCurrentTimeSlot();
    final token = generateDynamicToken(deviceToken: deviceToken, secretKey: secretKey, timeSlot: slot);
    
    final uri = Uri.parse(baseUrl);
    final queryParams = Map<String, String>.from(uri.queryParameters);
    queryParams['device_id'] = deviceToken;
    queryParams['token'] = token;
    queryParams['ts'] = slot.toString();

    return uri.replace(queryParameters: queryParams).toString();
  }

  /// Builds HTTP headers with dynamic security tokens
  static Map<String, String> buildSecureHeaders(String deviceToken, {String secretKey = defaultSecretKey}) {
    final slot = getCurrentTimeSlot();
    final token = generateDynamicToken(deviceToken: deviceToken, secretKey: secretKey, timeSlot: slot);
    
    return {
      "X-Device-Token": deviceToken,
      "X-Dynamic-Token": token,
      "X-Time-Slot": slot.toString(),
    };
  }
}
