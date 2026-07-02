import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'db_service.dart';

class ApiService {
  static const String _geminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY');
  static const String _geminiModel =
      String.fromEnvironment('GEMINI_MODEL', defaultValue: 'gemini-2.5-flash');
  static const String _backendEvaluatorUrl =
      String.fromEnvironment('BACKEND_EVALUATOR_URL');

  static Future<Map<String, dynamic>?> evaluateContent({
    required String title,
    required String channel,
    required String extractedText,
    String appName = 'YouTube',
    String? focusGoal,
    List<String> userKeywords = const [],
  }) async {
    final userId = await AuthService().currentUserId();
    final resolvedFocusGoal =
        focusGoal ?? await DatabaseService().getFocusGoal(userId: userId);

    if (_geminiApiKey.isNotEmpty) {
      return _evaluateWithGemini(
        title: title,
        channel: channel,
        extractedText: extractedText,
        appName: appName,
        focusGoal: resolvedFocusGoal,
      );
    }

    if (_backendEvaluatorUrl.isNotEmpty) {
      return _evaluateWithBackend(
        title: title,
        channel: channel,
        extractedText: extractedText,
        appName: appName,
        focusGoal: resolvedFocusGoal,
      );
    }

    developer.log(
      'No GEMINI_API_KEY or BACKEND_EVALUATOR_URL configured; using local fallback',
      name: 'ApiService',
    );
    return _localFallback(
      title: title,
      channel: channel,
      extractedText: extractedText,
      focusGoal: resolvedFocusGoal,
      userKeywords: userKeywords,
    );
  }

  static Future<Map<String, dynamic>> _evaluateWithGemini({
    required String title,
    required String channel,
    required String extractedText,
    required String appName,
    required String focusGoal,
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$_geminiModel:generateContent',
    );

    final prompt = '''
You are a semantic relevance scorer for an AI productivity monitor.

The user's career goal is: "$focusGoal"

Before scoring, infer the full skill domain this goal belongs to.
For example:
- "Flutter Developer" → mobile development, Dart, software engineering, CS fundamentals, APIs, UI/UX, JavaScript/TypeScript/web (adjacent ecosystem), system design, career growth in tech
- "Medical Student" → anatomy, physiology, pathology, pharmacology, clinical skills, MBBS prep, biology, biochemistry, research
- "Data Scientist" → Python, machine learning, statistics, data visualization, SQL, AI research, maths, Kaggle, model deployment
- "Filmmaker" → cinematography, video editing, color grading, storytelling, screenwriting, production workflow, camera techniques
- "Business Analyst" → market research, finance, Excel/SQL/BI tools, strategy, case studies, communication, MBA prep
- "Graphic Designer" / "UI/UX Designer" → Figma, Illustrator, design systems, typography, color theory, UX research, prototyping

Apply the same reasoning to any goal not listed above.

Now evaluate this content:
App: "$appName"
Channel/account: "$channel"
Title: "$title"
Visible text: "$extractedText"

Scoring rules:
- 0.80–1.00: Core skill content — directly teaches or demonstrates the goal's primary domain (tutorials, deep dives, projects, case studies, interview prep)
- 0.55–0.79: Adjacent or supportive — clearly useful for someone in this career path, even if not the primary tool (e.g. JavaScript for a Flutter developer, statistics for a data scientist)
- 0.30–0.54: Loosely related — general tech/education/professional content with weak goal alignment
- 0.00–0.29: Not relevant — entertainment, sports, gossip, memes, gaming, unrelated news, celebrity content, or casual scrolling even if the title sounds educational

Key judgment calls:
- A video that TEACHES or EXPLAINS something in the goal's domain scores 0.55+, even if the tool/language is adjacent
- A video that is merely INTERESTING or TRENDING but not educational scores below 0.30
- Channel name matters: a credible educational channel raises the score; a lifestyle/entertainment channel lowers it
- Ignore clickbait framing; judge what the content actually teaches

Return only valid JSON:
{
  "is_productive": true or false,
  "relevance_score": number from 0.0 to 1.0,
  "label": "productive" or "unproductive",
  "reason": "short reason under 18 words"
}
''';

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': _geminiApiKey,
            },
            body: jsonEncode({
              'contents': [
                {
                  'role': 'user',
                  'parts': [
                    {'text': prompt},
                  ],
                },
              ],
              'generationConfig': {
                'temperature': 0,
                'responseMimeType': 'application/json',
              },
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        developer.log(
          'Gemini returned HTTP ${response.statusCode}: ${response.body}',
          name: 'ApiService',
        );
        return _localFallback(
          title: title,
          channel: channel,
          extractedText: extractedText,
          focusGoal: focusGoal,
          source: response.statusCode == 429
              ? 'gemini_quota_fallback'
              : 'gemini_http_fallback',
          reason: response.statusCode == 429
              ? 'Gemini quota exceeded; local backup used.'
              : 'Gemini HTTP error; local backup used.',
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final text = _extractGeminiText(decoded);
      final verdict = _parseJsonObject(text);
      final score = _asDouble(verdict['relevance_score']).clamp(0.0, 1.0);
      final isProductive = verdict['is_productive'] == true || score >= 0.55;

      return {
        'is_productive': isProductive,
        'relevance_score': score,
        'label': isProductive ? 'productive' : 'unproductive',
        'reason': verdict['reason']?.toString() ?? '',
        'semantic_score': score,
        'behavior_score': null,
        'source': 'gemini_direct',
        'error': false,
      };
    } on SocketException catch (e, stackTrace) {
      developer.log(
        'Gemini socket error; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
        source: 'gemini_socket_fallback',
        reason: 'Gemini network error; local backup used.',
      );
    } on TimeoutException catch (e, stackTrace) {
      developer.log(
        'Gemini timed out; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
        source: 'gemini_timeout_fallback',
        reason: 'Gemini timed out; local backup used.',
      );
    } catch (e, stackTrace) {
      developer.log(
        'Gemini unexpected error; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
        source: 'gemini_error_fallback',
        reason: 'Gemini error; local backup used.',
      );
    }
  }

  static Future<Map<String, dynamic>> _evaluateWithBackend({
    required String title,
    required String channel,
    required String extractedText,
    required String appName,
    required String focusGoal,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(_backendEvaluatorUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': title,
          'channel': channel,
          'extracted_text': extractedText,
          'career_goal': focusGoal,
          'app_name': appName,
        }),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body) as Map<String, dynamic>;
        result['error'] = result['error'] == true;
        return result;
      }

      developer.log(
        'Backend evaluator returned HTTP ${response.statusCode}: ${response.body}',
        name: 'ApiService',
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
      );
    } on SocketException catch (e, stackTrace) {
      developer.log(
        'Backend evaluator socket error; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
      );
    } on TimeoutException catch (e, stackTrace) {
      developer.log(
        'Backend evaluator timed out; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
      );
    } catch (e, stackTrace) {
      developer.log(
        'Backend evaluator unexpected error; using local fallback',
        name: 'ApiService',
        error: e,
        stackTrace: stackTrace,
      );
      return _localFallback(
        title: title,
        channel: channel,
        extractedText: extractedText,
        focusGoal: focusGoal,
      );
    }
  }

  static String _extractGeminiText(Map<String, dynamic> decoded) {
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const FormatException('Gemini response has no candidates');
    }

    final content = candidates.first['content'];
    final parts = content?['parts'];
    if (parts is! List || parts.isEmpty) {
      throw const FormatException('Gemini response has no text parts');
    }

    return parts
        .map((part) => part is Map ? part['text']?.toString() ?? '' : '')
        .join()
        .trim();
  }

  static Map<String, dynamic> _parseJsonObject(String text) {
    final trimmed = text.trim();
    try {
      return jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start == -1 || end <= start) rethrow;
      return jsonDecode(trimmed.substring(start, end + 1))
          as Map<String, dynamic>;
    }
  }

  static Map<String, dynamic> _localFallback({
    required String title,
    required String channel,
    required String extractedText,
    required String focusGoal,
    List<String> userKeywords = const [],
    String source = 'local_fallback',
    String reason = 'Local keyword scoring used.',
  }) {
    final local = _PersonalizedLocalEvaluator.evaluate(
      title: title,
      channel: channel,
      extractedText: extractedText,
      focusGoal: focusGoal,
      userKeywords: userKeywords,
    );
    final relevanceScore = local.score;
    final isProductive = relevanceScore >= 0.55;

    return {
      'is_productive': isProductive,
      'relevance_score': relevanceScore,
      'label': isProductive ? 'productive' : 'unproductive',
      'reason': '$reason ${local.reason}',
      'semantic_score': relevanceScore,
      'behavior_score': null,
      'source': source,
      'error': false,
    };
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }
}

class _PersonalizedLocalEvaluation {
  final double score;
  final String reason;

  const _PersonalizedLocalEvaluation({
    required this.score,
    required this.reason,
  });
}

class _PersonalizedLocalEvaluator {
  static const _domainTerms = {
    'software': [
      'code',
      'coding',
      'programming',
      'software',
      'developer',
      'development',
      'computer science',
      'data structures',
      'algorithm',
      'algorithms',
      'c++',
      'cpp',
      'c#',
      'python',
      'java',
      'javascript',
      'typescript',
      'dart',
      'flutter',
      'android',
      'firebase',
      'api',
      'database',
      'sql',
      'git',
      'debugging',
      'leetcode',
    ],
    'filmmaking': [
      'film',
      'filmmaking',
      'cinematography',
      'camera',
      'lighting',
      'editing',
      'video editing',
      'premiere pro',
      'after effects',
      'davinci',
      'color grading',
      'storyboard',
      'screenplay',
      'director',
      'b-roll',
    ],
    'medical': [
      'medical',
      'medicine',
      'doctor',
      'anatomy',
      'physiology',
      'pathology',
      'clinical',
      'pharmacology',
      'surgery',
      'diagnosis',
      'patient',
      'mbbs',
      'nursing',
      'biology',
    ],
    'business': [
      'business',
      'startup',
      'marketing',
      'sales',
      'finance',
      'accounting',
      'investment',
      'management',
      'strategy',
      'entrepreneur',
      'productivity',
      'case study',
    ],
    'design': [
      'design',
      'ui',
      'ux',
      'figma',
      'wireframe',
      'prototype',
      'typography',
      'branding',
      'illustration',
      'photoshop',
    ],
  };

  static const _learningIntentTerms = [
    'tutorial',
    'course',
    'lecture',
    'learn',
    'lesson',
    'guide',
    'explained',
    'explanation',
    'beginner',
    'advanced',
    'roadmap',
    'project',
    'build',
    'full course',
    'masterclass',
    'interview',
    'career',
  ];

  static const _distractionTerms = [
    'funny',
    'comedy',
    'prank',
    'meme',
    'viral',
    'gossip',
    'drama',
    'reaction',
    'roast',
    'cricket',
    'football',
    'sports',
    'song',
    'music video',
    'vlog',
    'shorts',
    'celebrity',
  ];

  static _PersonalizedLocalEvaluation evaluate({
    required String title,
    required String channel,
    required String extractedText,
    required String focusGoal,
    List<String> userKeywords = const [],
  }) {
    final text = _normalize('$title $channel $extractedText');
    final goal = _normalize(focusGoal);
    final goalTerms = _goalTerms(goal);
    final inferredDomains = _inferDomains(goalTerms);
    final expandedTerms = <String>{
      ...goalTerms,
      for (final domain in inferredDomains) ...?_domainTerms[domain],
      for (final kw in userKeywords)
        if (kw.trim().length >= 2) kw.trim().toLowerCase(),
    };

    final goalHits = _hitCount(text, goalTerms);
    final userKeywordHits = userKeywords.isEmpty
        ? 0
        : _hitCount(text, userKeywords.map((k) => k.trim().toLowerCase()));
    final expandedHits = _hitCount(text, expandedTerms) - goalHits - userKeywordHits;
    final learningHits = _hitCount(text, _learningIntentTerms);
    final distractionHits = _hitCount(text, _distractionTerms);
    final hasGoalSignal = goalHits > 0 || userKeywordHits > 0 || expandedHits > 0;
    var score = 0.18;
    score += goalHits * 0.24;
    score += userKeywordHits * 0.24;
    score += expandedHits * 0.10;
    score += learningHits * (hasGoalSignal ? 0.10 : 0.04);

    if (text.contains(goal) && goal.length >= 4) {
      score += 0.18;
    }
    if (hasGoalSignal && learningHits > 0) {
      score += 0.12;
    }

    final distractionPenalty = hasGoalSignal ? 0.035 : 0.10;
    score -= distractionHits * distractionPenalty;

    final relevanceScore = score.clamp(0.0, 1.0);
    final reason = hasGoalSignal
        ? 'Local matched ${goalHits + expandedHits} goal/domain terms.'
        : 'Local found weak goal relevance.';

    return _PersonalizedLocalEvaluation(
      score: relevanceScore,
      reason: reason,
    );
  }

  static Set<String> _goalTerms(String goal) {
    final terms = goal
        .split(RegExp(r'[^a-z0-9+#]+'))
        .where((term) => term.length >= 3)
        .toSet();

    if (goal.trim().length >= 4) {
      terms.add(goal.trim());
    }
    return terms;
  }

  static Set<String> _inferDomains(Set<String> goalTerms) {
    final domains = <String>{};
    for (final entry in _domainTerms.entries) {
      if (entry.value.any(goalTerms.contains) || goalTerms.contains(entry.key)) {
        domains.add(entry.key);
      }
    }
    return domains;
  }

  static int _hitCount(String text, Iterable<String> terms) {
    var count = 0;
    for (final term in terms) {
      if (term.trim().isNotEmpty && text.contains(_normalize(term))) {
        count += 1;
      }
    }
    return count;
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
