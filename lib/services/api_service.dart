import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'db_service.dart';

class ApiService {
  static const String evaluateContentUrl =
      'http://192.168.100.201:8000/evaluate_content';

  static Future<Map<String, dynamic>?> evaluateContent({
    required String title,
    required String channel,
    required String extractedText,
    String? focusGoal,
  }) async {
    final resolvedFocusGoal =
        focusGoal ?? await DatabaseService().getFocusGoal();

    try {
      final response = await http.post(
        Uri.parse(evaluateContentUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'channel': channel,
          'extracted_text': extractedText,
          'career_goal': resolvedFocusGoal,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }

      developer.log(
        'AI API returned HTTP ${response.statusCode}: ${response.body}',
        name: 'ApiService',
      );
      return _offlineFallback();
    } on SocketException catch (e, stackTrace) {
      developer.log(
        'AI API socket error',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _offlineFallback();
    } on TimeoutException catch (e, stackTrace) {
      developer.log(
        'AI API timed out',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _offlineFallback();
    } catch (e, stackTrace) {
      developer.log(
        'AI API unexpected error',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _offlineFallback();
    }
  }

  static Map<String, dynamic> _offlineFallback() {
    return {
      'is_productive': false,
      'relevance_score': 0.0,
      'error': true,
      'source': 'ai_offline',
    };
  }
}
