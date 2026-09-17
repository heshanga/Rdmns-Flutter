import 'dart:async';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

class LiveNotificationService {
  static final LiveNotificationService _instance = LiveNotificationService._internal();
  factory LiveNotificationService() => _instance;
  LiveNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  Timer? _timer;
  int _lastStatus = -1;
  String _userId = "user_flutter_101";

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _notificationsPlugin.initialize(initSettings);
  }

  void startLiveStatusPolling({String? userId}) {
    if (userId != null && userId.isNotEmpty) {
      _userId = userId;
    }
    stopLiveStatusPolling();

    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      checkStatusFromApi();
    });
    checkStatusFromApi();
  }

  void stopLiveStatusPolling() {
    _timer?.cancel();
    _timer = null;
    _lastStatus = -1;
  }

  Future<void> checkStatusFromApi() async {
    final url = Uri.parse("https://rdmns.hesn.xyz/api/status.php?userId=$_userId");
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final status = data['status'] ?? 0;
        final title = data['title'] ?? '';
        final message = data['message'] ?? '';
        final progress = data['progress'] ?? 0;

        if (status > 0 && status != _lastStatus) {
          _lastStatus = status;
          showLiveNotification(status: status, customTitle: title, customMessage: message, customProgress: progress);
        }
      }
    } catch (_) {}
  }

  Future<void> showLiveNotification({
    required int status,
    String customTitle = '',
    String customMessage = '',
    int customProgress = 0,
  }) async {
    String title;
    String message;
    int progress;

    switch (status) {
      case 1:
        title = customTitle.isNotEmpty ? customTitle : "🛒 Order Received";
        message = customMessage.isNotEmpty ? customMessage : "Your order has been placed successfully.";
        progress = customProgress > 0 ? customProgress : 20;
        break;
      case 2:
        title = customTitle.isNotEmpty ? customTitle : "🍳 Preparing Your Order";
        message = customMessage.isNotEmpty ? customMessage : "The kitchen is currently preparing your meal.";
        progress = customProgress > 0 ? customProgress : 40;
        break;
      case 3:
        title = customTitle.isNotEmpty ? customTitle : "🛵 On The Way";
        message = customMessage.isNotEmpty ? customMessage : "Delivery partner is on the way to your location.";
        progress = customProgress > 0 ? customProgress : 60;
        break;
      case 4:
        title = customTitle.isNotEmpty ? customTitle : "📍 Arriving Soon";
        message = customMessage.isNotEmpty ? customMessage : "Delivery partner is nearby! Please get ready.";
        progress = customProgress > 0 ? customProgress : 80;
        break;
      case 5:
        title = customTitle.isNotEmpty ? customTitle : "✅ Order Delivered";
        message = customMessage.isNotEmpty ? customMessage : "Enjoy your order! Thank you for choosing Rdmns.";
        progress = customProgress > 0 ? customProgress : 100;
        break;
      default:
        return;
    }

    final androidDetails = AndroidNotificationDetails(
      'rdmns_flutter_live',
      'Live Order Tracking',
      channelDescription: 'Uber Eats style live status progress notifications',
      importance: Importance.high,
      priority: Priority.high,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      ongoing: status < 5,
    );

    const iosDetails = DarwinNotificationDetails();
    final platformDetails = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _notificationsPlugin.show(1001, title, message, platformDetails);
  }
}
