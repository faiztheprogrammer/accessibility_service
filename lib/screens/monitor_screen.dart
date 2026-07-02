import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/behavior_analytics_service.dart';
import '../services/db_service.dart';
import '../services/decision_engine.dart';
import 'dashboard_screen.dart';
import 'profile_screen.dart';

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _logEntries = [];
  bool _isServiceActive = false;
  bool _isOfflineMode = false;

  // Banner state
  String _bannerTitle = 'Monitoring Active';
  String _bannerMessage = 'Watching for content…';
  Color _bannerColor = const Color(0xFF5C6BC0);

  // DB session tracking
  int? _currentSessionId;
  String _lastAppPackage = '';
  Timer? _sessionIdleTimer;
  static const Duration _sessionIdleTimeout = Duration(minutes: 5);

  late MethodChannel _platformChannel;
  final DecisionEngine _decisionEngine = DecisionEngine();
  final BehaviorAnalyticsService _analyticsService = BehaviorAnalyticsService();

  @override
  void initState() {
    super.initState();
    _platformChannel =
        const MethodChannel('com.example.accessibility_service/monitor');
    WidgetsBinding.instance.addObserver(this);
    _initChannel();
    _refreshMonitorState();
  }

  @override
  void dispose() {
    _sessionIdleTimer?.cancel();
    _closeCurrentSession();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshMonitorState();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _closeCurrentSession();
    }
  }

  Future<void> _refreshMonitorState() async {
    await Future.wait([
      _syncNotificationListenerPermission(),
      _loadHistoricalData(),
    ]);
  }

  Future<void> _syncNotificationListenerPermission() async {
    try {
      final isEnabled =
          await _platformChannel.invokeMethod<bool>('is_notification_listener_enabled');
      if (!mounted) return;
      setState(() => _isServiceActive = isEnabled ?? false);
    } on PlatformException {
      if (!mounted) return;
      setState(() => _isServiceActive = false);
    }
  }

  Future<void> _loadHistoricalData() async {
    final logs = await DatabaseService().getRecentContent();
    if (!mounted) return;
    setState(() {
      _logEntries = logs.map((row) => {
        'app': row['app_name'],
        'content': row['title'] ?? row['extracted_text'],
        'time': DateTime.parse(row['timestamp']),
        'isProductive': row['is_productive'] == 1,
        'relevanceScore': row['relevance_score'],
        'behaviorRiskScore': row['behavior_risk_score'],
        'decisionLabel': row['decision_label'],
        'source': row['source'] ?? 'api',
      }).toList();
    });
  }

  void _initChannel() {
    _platformChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'service_status':
          final isRunning = (call.arguments['isRunning'] ?? false) as bool;
          setState(() => _isServiceActive = isRunning);
          break;

        case 'content_extracted':
          final package = call.arguments['package'] ?? 'unknown';
          final text = call.arguments['text'] ?? '';
          final title = call.arguments['title'] ?? '';
          final channel = call.arguments['channel'] ?? '';
          if (text.isNotEmpty || title.isNotEmpty) {
            final displayTitle = title.isNotEmpty ? title : text;
            final appName = _getAppName(package);

            setState(() {
              _bannerTitle = 'Analyzing…';
              _bannerMessage = displayTitle;
              _bannerColor = const Color(0xFF5C6BC0);
            });

            if (package != _lastAppPackage || _currentSessionId == null) {
              if (_currentSessionId != null) await _closeCurrentSession();
              _lastAppPackage = package;
              _currentSessionId =
                  await DatabaseService().insertSession(appName);
            }
            await _markSessionActivity(_currentSessionId!);
            await _analyzeContent(appName, _currentSessionId!, title, channel, text);
          }
          break;
      }
    });
  }

  String _getAppName(String package) {
    const appNames = {
      'com.facebook.katana': 'Facebook',
      'com.twitter.android': 'Twitter / X',
      'com.linkedin.android': 'LinkedIn',
      'com.instagram.android': 'Instagram',
      'com.google.android.youtube': 'YouTube',
    };
    return appNames[package] ?? package;
  }

  void _addLog(
    String app,
    String content,
    bool? isProductive, {
    String? source,
    String? decisionLabel,
    double? behaviorRiskScore,
    double? relevanceScore,
  }) {
    if (!mounted) return;
    setState(() {
      _logEntries.insert(0, {
        'app': app,
        'content': content,
        'time': DateTime.now(),
        'isProductive': isProductive,
        'source': source,
        'decisionLabel': decisionLabel,
        'behaviorRiskScore': behaviorRiskScore,
        'relevanceScore': relevanceScore,
      });
      if (_logEntries.length > 50) _logEntries.removeLast();
    });
  }

  Future<void> _analyzeContent(
    String appName,
    int sessionId,
    String title,
    String channel,
    String text,
  ) async {
    late final DecisionResult result;
    try {
      result = await _decisionEngine
          .evaluateAndPersist(
            sessionId: sessionId,
            appName: appName,
            title: title,
            channel: channel,
            extractedText: text,
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      final displayTitle = title.isNotEmpty ? title : text;
      _addLog(appName, displayTitle, false, source: 'ai_timeout');
      if (!mounted) return;
      setState(() {
        _isOfflineMode = true;
        _bannerTitle = 'Local Evaluation Active';
        _bannerMessage = 'Cloud scoring timed out — running locally.';
        _bannerColor = Colors.orange.shade700;
      });
      return;
    } catch (e) {
      final displayTitle = title.isNotEmpty ? title : text;
      _addLog(appName, displayTitle, false, source: 'evaluation_error');
      if (!mounted) return;
      setState(() {
        _isOfflineMode = true;
        _bannerTitle = 'Local Evaluation Active';
        _bannerMessage = 'Cloud scoring failed — running locally.';
        _bannerColor = Colors.orange.shade700;
      });
      return;
    }

    _addLog(
      appName,
      result.title,
      result.isProductive,
      source: result.source,
      decisionLabel: result.decisionLabel,
      behaviorRiskScore: result.behaviorRiskScore,
      relevanceScore: result.relevanceScore,
    );

    await _markSessionActivity(sessionId);
    await _analyticsService.calculateAndPersistDailySummary(
        appCategory: appName);

    if (!mounted) return;
    final isLocal = result.hasError ||
        result.source.contains('ai_offline') ||
        result.source.contains('local_backup') ||
        result.source.contains('local_fallback') ||
        result.source.contains('fallback') ||
        result.source.contains('quota');

    setState(() {
      _isOfflineMode = isLocal;
      if (result.hasError || result.source.contains('ai_offline')) {
        _bannerTitle = 'Local Evaluation Active';
        _bannerMessage = 'Cloud scoring unavailable — running locally.';
        _bannerColor = Colors.orange.shade700;
      } else if (isLocal) {
        _bannerTitle =
            'Local Score  ${(result.relevanceScore * 100).toInt()}%';
        _bannerMessage = result.decisionReason;
        _bannerColor = result.isProductive
            ? Colors.green.shade700
            : Colors.red.shade700;
      } else if (result.decisionLabel == 'productive_high_risk') {
        _bannerTitle =
            'Productive, High Usage  ${(result.relevanceScore * 100).toInt()}%';
        _bannerMessage =
            'Session risk ${(result.behaviorRiskScore * 100).toInt()}% — consider a break.';
        _bannerColor = Colors.orange.shade700;
      } else if (result.isProductive) {
        _bannerTitle =
            'Productive  ${(result.relevanceScore * 100).toInt()}%';
        _bannerMessage = result.decisionReason;
        _bannerColor = Colors.green.shade700;
      } else {
        _bannerTitle = switch (result.decisionLabel) {
          'high_distraction_risk' => 'High Distraction Risk',
          'contextual_distraction' => 'Contextual Distraction',
          _ => 'Possible Distraction',
        };
        _bannerMessage = result.decisionReason;
        _bannerColor = Colors.red.shade700;
      }
    });

    await _updateServiceNotification(result);
    if (result.interventionTier != null) {
      await _triggerIntervention(result.interventionTier!, result);
    }
  }

  Future<void> _updateServiceNotification(DecisionResult result) async {
    final title = switch (result.decisionLabel) {
      'productive_high_risk' => 'Productive, But Prolonged',
      'high_distraction_risk' => 'High Distraction Risk',
      'contextual_distraction' => 'Contextual Distraction',
      'possible_distraction' => 'Possible Distraction',
      _ => 'Productive Mode',
    };
    final score = (result.relevanceScore * 100).toInt();
    final behavior = (result.behaviorRiskScore * 100).toInt();
    final sourceLabel = result.source.contains('gemini_direct')
        ? 'Gemini'
        : result.source.contains('gemini_quota')
            ? 'Gemini → Local'
            : result.fromCache
                ? 'Cache'
                : result.source.contains('fallback') ||
                        result.source.contains('local')
                    ? 'Local'
                    : 'AI';
    final text =
        '$score% $sourceLabel · $behavior% risk · ${result.title}';

    try {
      await _platformChannel.invokeMethod('update_service_notification', {
        'title': title,
        'text': text,
      });
    } on PlatformException {
      // Notification refresh is best-effort.
    }
  }

  Future<void> _triggerIntervention(int tier, DecisionResult result) async {
    if (!mounted) return;

    final distractionLabel = switch (result.decisionLabel) {
      'high_distraction_risk' => 'High Distraction Risk',
      'contextual_distraction' => 'Contextual Distraction',
      _ => 'Possible Distraction',
    };

    if (tier == 1) {
      // Tier 1 — update banner only, no dialog
      setState(() {
        _bannerTitle = 'Heads Up';
        _bannerMessage = 'This content doesn\'t align with your goal.';
        _bannerColor = Colors.orange.shade700;
      });
      return;
    }

    if (tier == 2) {
      // Tier 2 — banner escalates + heads-up notification (visible on YouTube)
      setState(() {
        _bannerTitle = 'Distraction Pattern Detected';
        _bannerMessage =
            'You\'ve seen ${result.consecutiveUnproductiveCount} distracting items in a row. Consider refocusing.';
        _bannerColor = Colors.deepOrange.shade700;
      });
      try {
        await _platformChannel.invokeMethod('show_intervention_alert', {
          'tier': 2,
          'message':
              'You\'ve watched ${result.consecutiveUnproductiveCount} distracting items in a row. Time to refocus on your goal.',
        });
      } on PlatformException {
        // Best-effort — fall back to in-app snackbar only
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'You\'ve been distracted for a while. Time to refocus?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              backgroundColor: Colors.deepOrange.shade700,
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Dismiss',
                textColor: Colors.white,
                onPressed: () {},
              ),
            ),
          );
        }
      }
      return;
    }

    // Tier 3 — full dialog intervention + heads-up notification
    setState(() {
      _bannerTitle = 'Focus Alert';
      _bannerMessage =
          '${result.consecutiveUnproductiveCount} distracting items in a row. You need a break.';
      _bannerColor = Colors.red.shade800;
    });
    try {
      await _platformChannel.invokeMethod('show_intervention_alert', {
        'tier': 3,
        'message':
            '${result.consecutiveUnproductiveCount} distracting items in a row. Put the phone down and get back to your goal.',
      });
    } on PlatformException {
      // Best-effort.
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        icon: Icon(Icons.warning_rounded, color: Colors.red.shade700, size: 40),
        title: const Text(
          'Time to Refocus',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          'You\'ve watched ${ result.consecutiveUnproductiveCount} distracting items in a row '
          '($distractionLabel). This is significantly impacting your focus score.\n\n'
          'Put the phone down and get back to your goal.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Got it, I\'ll refocus'),
          ),
        ],
      ),
    );
  }

  Future<void> _closeCurrentSession() async {
    _sessionIdleTimer?.cancel();
    _sessionIdleTimer = null;
    final sessionId = _currentSessionId;
    if (sessionId == null) return;
    await DatabaseService().updateSessionEndTime(sessionId);
    _currentSessionId = null;
    _lastAppPackage = '';
  }

  Future<void> _markSessionActivity(int sessionId) async {
    await DatabaseService().updateSessionEndTime(sessionId);
    _scheduleSessionIdleTimeout(sessionId);
  }

  void _scheduleSessionIdleTimeout(int sessionId) {
    _sessionIdleTimer?.cancel();
    _sessionIdleTimer = Timer(_sessionIdleTimeout, () {
      if (_currentSessionId == sessionId) _closeCurrentSession();
    });
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surface,
        titleSpacing: 12,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_rounded, color: cs.primary, size: 20),
            const SizedBox(width: 6),
            const Text('FocusGuard',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(width: 8),
            _ServiceStatusChip(isActive: _isServiceActive),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Dashboard',
            icon: const Icon(Icons.bar_chart_rounded, size: 22),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DashboardScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline_rounded, size: 22),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep_outlined, size: 22),
            onPressed: () => setState(() => _logEntries.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isOfflineMode) _OfflineBanner(),
          _ServiceCard(
            isActive: _isServiceActive,
            onOpenSettings: () =>
                _platformChannel.invokeMethod('open_notification_settings'),
          ),
          _LogHeader(count: _logEntries.length),
          Expanded(
            child: _logEntries.isEmpty
                ? _EmptyLogState()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: _logEntries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) =>
                        _LogCard(entry: _logEntries[index]),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _StatusBanner(
        title: _bannerTitle,
        message: _bannerMessage,
        color: _bannerColor,
        bottomPadding: MediaQuery.of(context).padding.bottom,
      ),
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────────

class _ServiceStatusChip extends StatelessWidget {
  const _ServiceStatusChip({required this.isActive});
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.green.withValues(alpha: 0.12)
              : Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? Icons.circle : Icons.circle_outlined,
              size: 8,
              color: isActive ? Colors.green.shade700 : Colors.orange.shade700,
            ),
            const SizedBox(width: 5),
            Text(
              isActive ? 'Live' : 'Off',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color:
                    isActive ? Colors.green.shade700 : Colors.orange.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.offline_bolt_rounded,
              size: 14, color: Colors.orange.shade800),
          const SizedBox(width: 6),
          Text(
            'Local scoring active — cloud unavailable',
            style: TextStyle(
                fontSize: 12,
                color: Colors.orange.shade800,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.isActive,
    required this.onOpenSettings,
  });
  final bool isActive;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activeColor = isActive ? Colors.green.shade700 : Colors.red.shade700;
    final bgColor = isActive
        ? Colors.green.withValues(alpha: 0.07)
        : Colors.red.withValues(alpha: 0.07);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: activeColor.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.shield_rounded : Icons.shield_outlined,
            color: activeColor,
            size: 36,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isActive ? 'Protection Active' : 'Service Inactive',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: activeColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Grant "Notification Access" in Settings to enable YouTube tracking.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: onOpenSettings,
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              textStyle: const TextStyle(fontSize: 12),
              side: BorderSide(color: activeColor.withValues(alpha: 0.5)),
            ),
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}

class _LogHeader extends StatelessWidget {
  const _LogHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            'Live Activity',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: cs.onSurface),
          ),
          const Spacer(),
          if (count > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyLogState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_outline_rounded,
                size: 64, color: cs.outlineVariant),
            const SizedBox(height: 16),
            Text(
              'No activity yet',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              'Open YouTube and start watching — FocusGuard will analyze content here in real time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entry});
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isProductive = entry['isProductive'] == true;
    final decisionLabel = entry['decisionLabel']?.toString() ?? '';
    final source = entry['source']?.toString() ?? '';
    final isHighRisk = decisionLabel == 'productive_high_risk';
    final isContextual = decisionLabel == 'contextual_distraction';
    final relevanceScore = entry['relevanceScore'] as double?;
    final time = entry['time'] as DateTime?;
    final isLocal = source.contains('local_backup') ||
        source.contains('local_fallback') ||
        source.contains('fallback') ||
        source.contains('quota');

    Color iconBg;
    Color iconColor;
    IconData iconData;
    if (isHighRisk) {
      iconBg = Colors.orange.withValues(alpha: 0.15);
      iconColor = Colors.orange.shade700;
      iconData = Icons.timer_outlined;
    } else if (isContextual) {
      iconBg = Colors.amber.withValues(alpha: 0.15);
      iconColor = Colors.amber.shade800;
      iconData = Icons.swap_horiz_rounded;
    } else if (isProductive) {
      iconBg = Colors.green.withValues(alpha: 0.12);
      iconColor = Colors.green.shade700;
      iconData = Icons.check_rounded;
    } else {
      iconBg = Colors.red.withValues(alpha: 0.10);
      iconColor = Colors.red.shade700;
      iconData = Icons.warning_amber_rounded;
    }

    return Card(
      elevation: 0,
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBg,
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, color: iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        entry['app']?.toString() ?? '',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: cs.onSurface,
                        ),
                      ),
                      if (isLocal) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.offline_bolt_rounded,
                            size: 12, color: cs.outline),
                      ],
                      const Spacer(),
                      if (time != null)
                        Text(
                          _formatTime(time),
                          style: TextStyle(
                              fontSize: 11, color: cs.outline),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry['content']?.toString() ?? '',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (relevanceScore != null) ...[
                    const SizedBox(height: 6),
                    _ScorePill(score: relevanceScore, isProductive: isProductive),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score, required this.isProductive});
  final double score;
  final bool isProductive;

  @override
  Widget build(BuildContext context) {
    final pct = (score * 100).toInt();
    final color = isProductive ? Colors.green.shade700 : Colors.red.shade700;
    final bg = isProductive
        ? Colors.green.withValues(alpha: 0.10)
        : Colors.red.withValues(alpha: 0.10);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        '$pct% relevance',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.title,
    required this.message,
    required this.color,
    this.bottomPadding = 0,
  });
  final String title;
  final String message;
  final Color color;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
      color: color,
      padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottomPadding),
      child: Row(
          children: [
            const Icon(Icons.notifications_active_rounded,
                color: Colors.white, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    message,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
    );
  }
}
