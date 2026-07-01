import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'db_service.dart';

class BehaviorRiskResult {
  final double riskScore;
  final double modelRiskScore;
  final double liveRiskScore;
  final String label;
  final Map<String, String> features;

  const BehaviorRiskResult({
    required this.riskScore,
    required this.modelRiskScore,
    required this.liveRiskScore,
    required this.label,
    required this.features,
  });

  bool get isHighRisk => riskScore >= 0.60;
}

class BehaviorModelService {
  static final BehaviorModelService _instance = BehaviorModelService._internal();

  factory BehaviorModelService() => _instance;

  BehaviorModelService._internal();

  final DatabaseService _db = DatabaseService();
  Map<String, dynamic>? _model;

  static const _binaryFeatures = [
    'is_weekend',
    'is_night',
    'has_calendar_event',
  ];

  static const _numericFeatures = [
    'hour',
    'day_of_week',
    'total_app_events',
    'unique_apps',
    'app_switches',
    'estimated_active_seconds',
    'academic_ratio',
    'productivity_ratio',
    'communication_ratio',
    'social_ratio',
    'entertainment_ratio',
    'utility_ratio',
    'unknown_ratio',
    'phone_lock_events',
    'locked_seconds',
    'activity_stationary_events',
    'activity_walking_events',
    'activity_running_events',
    'study_productivity',
    'stress_level',
    'sleep_hours',
  ];

  Future<BehaviorRiskResult> evaluate({
    required int sessionId,
    required String appName,
  }) async {
    final model = await _loadModel();
    final features = await _buildFeatures(sessionId: sessionId, appName: appName);
    final tokens = _featureTokens(features);
    final modelRiskScore = _predictHighRiskProbability(model, tokens);
    final liveRiskScore = _liveBehaviorRisk(features, appName);
    final riskScore = math.max(
      modelRiskScore,
      (modelRiskScore * 0.45) + (liveRiskScore * 0.55),
    );
    return BehaviorRiskResult(
      riskScore: riskScore,
      modelRiskScore: modelRiskScore,
      liveRiskScore: liveRiskScore,
      label: riskScore >= 0.60 ? 'high_behavior_risk' : 'low_behavior_risk',
      features: features,
    );
  }

  Future<Map<String, dynamic>> _loadModel() async {
    final cached = _model;
    if (cached != null) return cached;

    final jsonText = await rootBundle.loadString(
      'machine_learning/exported_models/studentlife_behavior_model.json',
    );
    _model = jsonDecode(jsonText) as Map<String, dynamic>;
    return _model!;
  }

  Future<Map<String, String>> _buildFeatures({
    required int sessionId,
    required String appName,
  }) async {
    final now = DateTime.now();
    final sessions = await _db.getSessionsForDate(now);
    final verdicts = await _db.getContentVerdictsForDate(now);
    final session = await _db.getSessionById(sessionId);
    final appCategory = _categoryForApp(appName);

    final currentHourItems = verdicts.where((row) {
      final timestamp = DateTime.tryParse(row['timestamp']?.toString() ?? '');
      return timestamp != null && timestamp.hour == now.hour;
    }).toList();

    final uniqueApps = sessions
        .map((row) => row['app_name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toSet()
        .length;

    var appSwitches = 0;
    var previousApp = '';
    for (final row in sessions) {
      final currentApp = row['app_name']?.toString() ?? '';
      if (previousApp.isNotEmpty && currentApp.isNotEmpty && currentApp != previousApp) {
        appSwitches += 1;
      }
      if (currentApp.isNotEmpty) previousApp = currentApp;
    }

    final sessionStart = DateTime.tryParse(session?['start_time']?.toString() ?? '');
    final activeSeconds = sessionStart == null
        ? 0
        : now.difference(sessionStart).inSeconds.clamp(0, 6 * 60 * 60);

    final ratios = {
      'academic_ratio': 0.0,
      'productivity_ratio': 0.0,
      'communication_ratio': 0.0,
      'social_ratio': 0.0,
      'entertainment_ratio': 0.0,
      'utility_ratio': 0.0,
      'unknown_ratio': 0.0,
    };
    ratios['${appCategory}_ratio'] = 1.0;

    // Derive proxy values for features the app cannot directly observe.
    // study_productivity: inferred from today's productive-verdict ratio (1–5 scale).
    final totalVerdicts = verdicts.length;
    final productiveVerdicts =
        verdicts.where((r) => r['is_productive']?.toString() == '1').length;
    final productiveRatio =
        totalVerdicts > 0 ? productiveVerdicts / totalVerdicts : 0.5;
    final studyProductivityProxy = (productiveRatio * 5.0).clamp(1.0, 5.0);

    // stress_level: inferred from distraction intensity (app switches + distraction ratio).
    final distractingVerdicts = totalVerdicts - productiveVerdicts;
    final distractionRatio =
        totalVerdicts > 0 ? distractingVerdicts / totalVerdicts : 0.0;
    final stressScore = (appSwitches * 0.15 + distractionRatio * 3.5).clamp(1.0, 5.0);

    // sleep_hours: not observable; use 6h as a neutral default.
    const sleepHoursProxy = 6.0;

    return {
      'hour': now.hour.toString(),
      'day_of_week': now.weekday == DateTime.sunday ? '6' : (now.weekday - 1).toString(),
      'is_weekend': (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) ? '1' : '0',
      'is_night': (now.hour >= 22 || now.hour < 6) ? '1' : '0',
      'has_calendar_event': '0',
      'total_app_events': math.max(currentHourItems.length + 1, 1).toString(),
      'unique_apps': math.max(uniqueApps, 1).toString(),
      'app_switches': appSwitches.toString(),
      'estimated_active_seconds': activeSeconds.toString(),
      'academic_ratio': ratios['academic_ratio']!.toString(),
      'productivity_ratio': ratios['productivity_ratio']!.toString(),
      'communication_ratio': ratios['communication_ratio']!.toString(),
      'social_ratio': ratios['social_ratio']!.toString(),
      'entertainment_ratio': ratios['entertainment_ratio']!.toString(),
      'utility_ratio': ratios['utility_ratio']!.toString(),
      'unknown_ratio': ratios['unknown_ratio']!.toString(),
      'phone_lock_events': '0',
      'locked_seconds': '0',
      'activity_stationary_events': '0',
      'activity_walking_events': '0',
      'activity_running_events': '0',
      'study_productivity': studyProductivityProxy.toStringAsFixed(1),
      'stress_level': stressScore.toStringAsFixed(1),
      'sleep_hours': sleepHoursProxy.toStringAsFixed(1),
    };
  }

  String _categoryForApp(String appName) {
    final normalized = appName.toLowerCase();
    if (normalized.contains('youtube') ||
        normalized.contains('instagram') ||
        normalized.contains('facebook') ||
        normalized.contains('tiktok') ||
        normalized.contains('netflix')) {
      return 'entertainment';
    }
    if (normalized.contains('linkedin') ||
        normalized.contains('gmail') ||
        normalized.contains('docs') ||
        normalized.contains('chrome')) {
      return 'productivity';
    }
    if (normalized.contains('whatsapp') ||
        normalized.contains('twitter') ||
        normalized.contains('telegram')) {
      return 'communication';
    }
    return 'unknown';
  }

  List<String> _featureTokens(Map<String, String> features) {
    return [
      for (final feature in _binaryFeatures)
        '$feature=${features[feature] ?? '0'}',
      for (final feature in _numericFeatures)
        _bucketFeature(feature, features[feature] ?? ''),
    ];
  }

  String _bucketFeature(String name, String value) {
    if (value.isEmpty) return '$name=missing';

    final numeric = double.tryParse(value);
    if (numeric == null) return '$name=$value';

    if (name == 'hour') {
      if (numeric >= 5 && numeric < 12) return 'hour=morning';
      if (numeric >= 12 && numeric < 17) return 'hour=afternoon';
      if (numeric >= 17 && numeric < 22) return 'hour=evening';
      return 'hour=night';
    }

    if (name == 'day_of_week') return 'day_of_week=${numeric.toInt()}';

    if (name.endsWith('_ratio')) {
      if (numeric == 0) return '$name=none';
      if (numeric < 0.25) return '$name=low';
      if (numeric < 0.60) return '$name=medium';
      return '$name=high';
    }

    if (name.endsWith('_seconds')) {
      if (numeric < 60) return '$name=under_1m';
      if (numeric < 5 * 60) return '$name=1m_5m';
      if (numeric < 30 * 60) return '$name=5m_30m';
      return '$name=over_30m';
    }

    if (name == 'study_productivity' ||
        name == 'stress_level' ||
        name == 'sleep_hours') {
      if (numeric <= 2) return '$name=low';
      if (numeric <= 4) return '$name=medium';
      return '$name=high';
    }

    if (numeric == 0) return '$name=none';
    if (numeric <= 3) return '$name=low';
    if (numeric <= 10) return '$name=medium';
    return '$name=high';
  }

  double _predictHighRiskProbability(
    Map<String, dynamic> model,
    List<String> tokens,
  ) {
    final vocabulary = (model['vocabulary'] as List<dynamic>).cast<String>();
    final tokenCounts = model['token_counts'] as Map<String, dynamic>;
    final classTokenTotals = model['class_token_totals'] as Map<String, dynamic>;
    final vocabSize = math.max(vocabulary.length, 1);

    final scores = <int, double>{};
    for (final label in [0, 1]) {
      final labelKey = label.toString();
      // Use a balanced (50/50) prior rather than the training distribution's 9:1
      // class imbalance, which would otherwise bury any high-risk signal.
      var score = math.log(0.5);
      final counts = (tokenCounts[labelKey] as Map<String, dynamic>?) ?? {};
      final tokenTotal =
          int.tryParse(classTokenTotals[labelKey]?.toString() ?? '') ?? 0;

      for (final token in tokens) {
        final count = int.tryParse(counts[token]?.toString() ?? '') ?? 0;
        score += math.log((count + 1) / (tokenTotal + vocabSize));
      }
      scores[label] = score;
    }

    final maxScore = math.max(scores[0]!, scores[1]!);
    final low = math.exp(scores[0]! - maxScore);
    final high = math.exp(scores[1]! - maxScore);
    return high / (low + high);
  }

  double _liveBehaviorRisk(Map<String, String> features, String appName) {
    final appCategory = _categoryForApp(appName);
    final activeSeconds = _asDouble(features['estimated_active_seconds']);
    final events = _asDouble(features['total_app_events']);
    final switches = _asDouble(features['app_switches']);
    final entertainmentRatio = _asDouble(features['entertainment_ratio']);
    final socialRatio = _asDouble(features['social_ratio']);
    final productivityRatio = _asDouble(features['productivity_ratio']);
    final isNight = features['is_night'] == '1';
    final isWeekend = features['is_weekend'] == '1';

    var risk = 0.04;

    if (appCategory == 'entertainment') {
      risk += 0.18;
    } else if (appCategory == 'social' || appCategory == 'communication') {
      risk += 0.10;
    } else if (appCategory == 'productivity') {
      risk -= 0.08;
    }

    risk += entertainmentRatio * 0.18;
    risk += socialRatio * 0.14;
    risk -= productivityRatio * 0.10;

    if (activeSeconds >= 60 * 60) {
      risk += 0.42;
    } else if (activeSeconds >= 30 * 60) {
      risk += 0.32;
    } else if (activeSeconds >= 15 * 60) {
      risk += 0.22;
    } else if (activeSeconds >= 5 * 60) {
      risk += 0.12;
    }

    if (events >= 12) {
      risk += 0.24;
    } else if (events >= 6) {
      risk += 0.16;
    } else if (events >= 3) {
      risk += 0.08;
    }

    risk += math.min(switches * 0.025, 0.15);

    if (isNight) risk += 0.16;
    if (isWeekend) risk -= 0.06;

    return risk.clamp(0.0, 1.0);
  }

  double _asDouble(String? value) {
    return double.tryParse(value ?? '') ?? 0.0;
  }
}
