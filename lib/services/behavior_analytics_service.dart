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
    final uniqueVerdicts = _dedupeVerdicts(matchingVerdicts);

    var nightUsage = false;
    final now = DateTime.now();
    final contentTimesBySession = <int, List<DateTime>>{};

    for (final row in matchingVerdicts) {
      final sessionId = _asInt(row['session_id']);
      final contentTime = _parseDate(row['timestamp']);
      if (sessionId > 0 && contentTime != null) {
        contentTimesBySession.putIfAbsent(sessionId, () => []).add(contentTime);
      }
      if (contentTime != null && _isNightHour(contentTime)) {
        nightUsage = true;
      }
    }

    final intervals = <_SessionInterval>[];
    for (final session in matchingSessions) {
      final sessionId = _asInt(session['id']);
      final start = _parseDate(session['start_time']);
      if (start == null) continue;

      final contentTimes = contentTimesBySession[sessionId] ?? const [];
      final explicitEnd = _parseDate(session['end_time']);
      final lastContent = _latestDate(contentTimes);
      final end = _boundedSessionEnd(
        start: start,
        explicitEnd: explicitEnd,
        lastContent: lastContent,
        now: now,
      );

      if (end.isAfter(start)) {
        intervals.add(_SessionInterval(start, end));
      }

      if (_isNightHour(start)) {
        nightUsage = true;
      }
    }

    final mergedIntervals = _mergeIntervals(intervals);
    final totalSeconds = mergedIntervals.fold<int>(
      0,
      (sum, interval) => sum + interval.end.difference(interval.start).inSeconds,
    );

    var productiveCount = 0;
    var unproductiveCount = 0;
    final unproductiveByApp = <String, int>{};

    for (final row in uniqueVerdicts) {
      final isProductive = row['is_productive'];
      if (isProductive == null) continue;

      if (isProductive == 1 || isProductive == true) {
        productiveCount += 1;
      } else {
        unproductiveCount += 1;
        final appName = row['app_name']?.toString() ?? appCategory;
        unproductiveByApp[appName] = (unproductiveByApp[appName] ?? 0) + 1;
      }
    }

    final totalVerdicts = productiveCount + unproductiveCount;
    final distractionRatio =
        totalVerdicts == 0 ? 0.0 : unproductiveCount / totalVerdicts;
    final focusScore = totalVerdicts == 0 ? 0.0 : 1.0 - distractionRatio;
    final sessionFrequency = mergedIntervals.length;
    final avgSessionDuration = sessionFrequency == 0
        ? 0.0
        : totalSeconds / sessionFrequency;

    return BehaviorSummary(
      metricDate: metricDate,
      appCategory: appCategory,
      avgSessionDuration: avgSessionDuration,
      nightUsage: nightUsage,
      sessionFrequency: sessionFrequency,
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

  List<Map<String, dynamic>> _dedupeVerdicts(
    List<Map<String, dynamic>> verdicts,
  ) {
    final latestByContent = <String, Map<String, dynamic>>{};
    for (final row in verdicts) {
      final title = row['title']?.toString().trim().toLowerCase() ?? '';
      if (title.isEmpty) continue;

      final channel = row['channel']?.toString().trim().toLowerCase() ?? '';
      final key = '$channel|$title';
      final currentTime = _parseDate(row['timestamp']);
      final previous = latestByContent[key];
      final previousTime = _parseDate(previous?['timestamp']);

      if (previous == null ||
          (currentTime != null &&
              (previousTime == null || currentTime.isAfter(previousTime)))) {
        latestByContent[key] = row;
      }
    }
    return latestByContent.values.toList();
  }

  DateTime _boundedSessionEnd({
    required DateTime start,
    required DateTime? explicitEnd,
    required DateTime? lastContent,
    required DateTime now,
  }) {
    var end = explicitEnd;

    if (end == null && lastContent != null) {
      end = lastContent.add(const Duration(minutes: 2));
    }

    end ??= start.add(const Duration(minutes: 2));
    if (end.isAfter(now)) end = now;

    final maxEnd = start.add(const Duration(hours: 2));
    if (end.isAfter(maxEnd)) end = maxEnd;

    return end;
  }

  List<_SessionInterval> _mergeIntervals(List<_SessionInterval> intervals) {
    if (intervals.isEmpty) return const [];

    final sorted = [...intervals]..sort((a, b) => a.start.compareTo(b.start));
    final merged = <_SessionInterval>[sorted.first];

    for (final interval in sorted.skip(1)) {
      final previous = merged.last;
      if (!interval.start.isAfter(previous.end)) {
        if (interval.end.isAfter(previous.end)) {
          merged[merged.length - 1] = _SessionInterval(
            previous.start,
            interval.end,
          );
        }
      } else {
        merged.add(interval);
      }
    }

    return merged;
  }

  bool _isNightHour(DateTime dateTime) {
    final hour = dateTime.toLocal().hour;
    return hour >= 22 || hour < 6;
  }

  DateTime? _latestDate(List<DateTime> dates) {
    if (dates.isEmpty) return null;
    var latest = dates.first;
    for (final date in dates.skip(1)) {
      if (date.isAfter(latest)) latest = date;
    }
    return latest;
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

class _SessionInterval {
  final DateTime start;
  final DateTime end;

  const _SessionInterval(this.start, this.end);
}
