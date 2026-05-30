import 'db_service.dart';

class BehaviorSummary {
  final String metricDate;
  final String appCategory;
  final double avgSessionDuration;
  final bool nightUsage;
  final int sessionFrequency;
  final int totalTimeToday;
  final int productiveCount;
  final int unproductiveCount;
  final double distractionRatio;
  final double focusScore;
  final String? topDistractingApp;

  const BehaviorSummary({
    required this.metricDate,
    required this.appCategory,
    required this.avgSessionDuration,
    required this.nightUsage,
    required this.sessionFrequency,
    required this.totalTimeToday,
    required this.productiveCount,
    required this.unproductiveCount,
    required this.distractionRatio,
    required this.focusScore,
    this.topDistractingApp,
  });

  int get totalVerdicts => productiveCount + unproductiveCount;

  Map<String, dynamic> toMap() {
    return {
      'metric_date': metricDate,
      'app_category': appCategory,
      'avg_session_duration': avgSessionDuration,
      'night_usage': nightUsage ? 1 : 0,
      'session_frequency': sessionFrequency,
      'total_time_today': totalTimeToday,
      'productive_count': productiveCount,
      'unproductive_count': unproductiveCount,
      'distraction_ratio': distractionRatio,
      'focus_score': focusScore,
      'top_distracting_app': topDistractingApp,
    };
  }
}

class BehaviorAnalyticsService {
  static final BehaviorAnalyticsService _instance =
      BehaviorAnalyticsService._internal();

  factory BehaviorAnalyticsService() => _instance;

  BehaviorAnalyticsService._internal();

  final DatabaseService _db = DatabaseService();

  Future<BehaviorSummary> calculateAndPersistDailySummary({
    DateTime? date,
    String appCategory = 'YouTube',
  }) async {
    final targetDate = date ?? DateTime.now();
    final summary = await calculateDailySummary(
      date: targetDate,
      appCategory: appCategory,
    );

    await _db.upsertBehavioralMetrics(
      metricDate: summary.metricDate,
      avgSessionDuration: summary.avgSessionDuration,
      nightUsage: summary.nightUsage,
      sessionFrequency: summary.sessionFrequency,
      totalTimeToday: summary.totalTimeToday,
      appCategory: summary.appCategory,
      productiveCount: summary.productiveCount,
      unproductiveCount: summary.unproductiveCount,
      distractionRatio: summary.distractionRatio,
      focusScore: summary.focusScore,
      topDistractingApp: summary.topDistractingApp,
    );

    return summary;
  }

  Future<BehaviorSummary> calculateDailySummary({
    DateTime? date,
    String appCategory = 'YouTube',
  }) async {
    final targetDate = date ?? DateTime.now();
    final metricDate = _dateKey(targetDate);
    final sessions = await _db.getSessionsForDate(targetDate);
    final contentVerdicts = await _db.getContentVerdictsForDate(targetDate);

    final matchingSessions = sessions
        .where((row) => _matchesAppCategory(row['app_name'], appCategory))
        .toList();
    final matchingVerdicts = contentVerdicts
        .where((row) => _matchesAppCategory(row['app_name'], appCategory))
        .toList();

    var totalSeconds = 0;
    var nightUsage = false;
    final now = DateTime.now();

    for (final session in matchingSessions) {
      final start = _parseDate(session['start_time']);
      if (start == null) continue;

      final end = _parseDate(session['end_time']) ?? now;
      final duration = end.difference(start);
      if (!duration.isNegative) {
        totalSeconds += duration.inSeconds;
      }

      if (_isNightHour(start)) {
        nightUsage = true;
      }
    }

    var productiveCount = 0;
    var unproductiveCount = 0;
    final unproductiveByApp = <String, int>{};

    for (final row in matchingVerdicts) {
      final isProductive = row['is_productive'];
      if (isProductive == null) continue;

      if (isProductive == 1 || isProductive == true) {
        productiveCount += 1;
      } else {
        unproductiveCount += 1;
        final appName = row['app_name']?.toString() ?? appCategory;
        unproductiveByApp[appName] = (unproductiveByApp[appName] ?? 0) + 1;
      }

      final contentTime = _parseDate(row['timestamp']);
      if (contentTime != null && _isNightHour(contentTime)) {
        nightUsage = true;
      }
    }

    final totalVerdicts = productiveCount + unproductiveCount;
    final distractionRatio =
        totalVerdicts == 0 ? 0.0 : unproductiveCount / totalVerdicts;
    final focusScore = totalVerdicts == 0 ? 0.0 : 1.0 - distractionRatio;
    final avgSessionDuration = matchingSessions.isEmpty
        ? 0.0
        : totalSeconds / matchingSessions.length;

    return BehaviorSummary(
      metricDate: metricDate,
      appCategory: appCategory,
      avgSessionDuration: avgSessionDuration,
      nightUsage: nightUsage,
      sessionFrequency: matchingSessions.length,
      totalTimeToday: totalSeconds,
      productiveCount: productiveCount,
      unproductiveCount: unproductiveCount,
      distractionRatio: distractionRatio,
      focusScore: focusScore,
      topDistractingApp: _topDistractingApp(unproductiveByApp),
    );
  }

  Future<BehaviorSummary?> getStoredDailySummary({
    DateTime? date,
    String appCategory = 'YouTube',
  }) async {
    final row = await _db.getBehavioralMetricsForDate(
      date: date ?? DateTime.now(),
      appCategory: appCategory,
    );

    if (row == null) return null;

    return BehaviorSummary(
      metricDate: row['metric_date']?.toString() ?? _dateKey(DateTime.now()),
      appCategory: row['app_category']?.toString() ?? appCategory,
      avgSessionDuration: _asDouble(row['avg_session_duration']),
      nightUsage: row['night_usage'] == 1 || row['night_usage'] == true,
      sessionFrequency: _asInt(row['session_frequency']),
      totalTimeToday: _asInt(row['total_time_today']),
      productiveCount: _asInt(row['productive_count']),
      unproductiveCount: _asInt(row['unproductive_count']),
      distractionRatio: _asDouble(row['distraction_ratio']),
      focusScore: _asDouble(row['focus_score']),
      topDistractingApp: row['top_distracting_app']?.toString(),
    );
  }

  bool _matchesAppCategory(dynamic appName, String appCategory) {
    final app = appName?.toString().toLowerCase() ?? '';
    final category = appCategory.toLowerCase();
    return app == category || app.contains(category);
  }

  bool _isNightHour(DateTime dateTime) {
    final hour = dateTime.toLocal().hour;
    return hour >= 22 || hour < 6;
  }

  String? _topDistractingApp(Map<String, int> counts) {
    if (counts.isEmpty) return null;

    var bestApp = counts.keys.first;
    var bestCount = counts[bestApp] ?? 0;

    for (final entry in counts.entries) {
      if (entry.value > bestCount) {
        bestApp = entry.key;
        bestCount = entry.value;
      }
    }

    return bestApp;
  }

  DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  String _dateKey(DateTime date) {
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}
