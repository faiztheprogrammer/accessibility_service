import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  // Use 127.0.0.1:8000 with 'adb reverse tcp:8000 tcp:8000' for physical devices
  static const String baseUrl = 'http://127.0.0.1:8000';

  static Future<Map<String, dynamic>?> evaluateContent({
    required String title,
    required String channel,
    required String extractedText,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/evaluate_content'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'channel': channel,
          'extracted_text': extractedText,
          'career_goal': 'Software Engineer',
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('API Error (Connection Lost?): $e');
      // FALLBACK: Simulating a local evaluation if the server is unreachable
      // This prevents the UI from getting "stuck" when the laptop is away.
      return _localHeuristicFallback(title, extractedText);
    }
    return null;
  }

  static Map<String, dynamic> _localHeuristicFallback(String title, String text) {
    final combined = '$title $text'.toLowerCase();
    final isProductive = combined.contains('tutorial') || combined.contains('code') || combined.contains('programming');
    return {
      'is_productive': isProductive,
      'relevance_score': isProductive ? 0.75 : 0.25,
      'source': 'local_backup'
    };
  }
}
