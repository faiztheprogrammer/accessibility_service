import 'package:flutter/material.dart';

import '../services/behavior_analytics_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final BehaviorAnalyticsService _analyticsService = BehaviorAnalyticsService();
  late Future<BehaviorSummary> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _analyticsService.calculateAndPersistDailySummary();
  }

  Future<void> _refresh() async {
    final future = _analyticsService.calculateAndPersistDailySummary();
    setState(() => _summaryFuture = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: const Text('Dashboard',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<BehaviorSummary>(
        future: _summaryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 48, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      'Could not load dashboard data.',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: cs.onSurface),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline, fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          }

          final summary = snapshot.data;
          if (summary == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bar_chart_rounded,
                        size: 64, color: cs.outlineVariant),
                    const SizedBox(height: 16),
                    Text(
                      'No data yet',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Start monitoring content on YouTube to see your productivity breakdown here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: cs.outline),
                    ),
                  ],
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _FocusScorePanel(summary: summary),
                const SizedBox(height: 16),
                _SectionLabel(label: 'Today\'s Activity'),
                const SizedBox(height: 10),
                _MetricsGrid(summary: summary),
                const SizedBox(height: 16),
                _SectionLabel(label: 'Details'),
                const SizedBox(height: 10),
                _DetailPanel(summary: summary),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: cs.outline,
      ),
    );
  }
}

class _FocusScorePanel extends StatelessWidget {
  const _FocusScorePanel({required this.summary});
  final BehaviorSummary summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scorePercent = (summary.focusScore * 100).round();
    final Color color;
    final String label;
    final IconData icon;
    if (scorePercent >= 70) {
      color = Colors.green.shade700;
      label = 'Great focus today!';
      icon = Icons.emoji_events_rounded;
    } else if (scorePercent >= 40) {
      color = Colors.orange.shade700;
      label = 'Room to improve';
      icon = Icons.trending_up_rounded;
    } else {
      color = Colors.red.shade700;
      label = 'High distraction detected';
      icon = Icons.warning_amber_rounded;
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 8),
                Text(
                  'Focus Score',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: cs.onSurface),
                ),
                const Spacer(),
                Text(
                  '$scorePercent%',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 28,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: summary.focusScore.clamp(0.0, 1.0),
                minHeight: 10,
                color: color,
                backgroundColor: color.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  summary.totalVerdicts == 0
                      ? 'No items evaluated yet'
                      : '${summary.productiveCount} productive · '
                          '${summary.unproductiveCount} distracting',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.summary});
  final BehaviorSummary summary;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: [
        _MetricTile(
          icon: Icons.timer_outlined,
          label: 'Time Today',
          value: _formatDuration(summary.totalTimeToday),
          color: Theme.of(context).colorScheme.primary,
        ),
        _MetricTile(
          icon: Icons.repeat_rounded,
          label: 'Sessions',
          value: summary.sessionFrequency.toString(),
          color: Theme.of(context).colorScheme.primary,
        ),
        _MetricTile(
          icon: Icons.check_circle_outline_rounded,
          label: 'Productive',
          value: summary.productiveCount.toString(),
          color: Colors.green.shade700,
        ),
        _MetricTile(
          icon: Icons.warning_amber_rounded,
          label: 'Distracting',
          value: summary.unproductiveCount.toString(),
          color: Colors.red.shade700,
        ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h == 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, size: 22, color: color),
            Text(
              value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface),
            ),
            Text(label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.summary});
  final BehaviorSummary summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distractionPct = (summary.distractionRatio * 100).round();
    final distractionColor = distractionPct >= 60
        ? Colors.red.shade700
        : distractionPct >= 30
            ? Colors.orange.shade700
            : Colors.green.shade700;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          _DetailRow(
            icon: Icons.schedule_rounded,
            label: 'Avg Session',
            value: _formatAverage(summary.avgSessionDuration),
            valueColor: null,
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          _DetailRow(
            icon: Icons.nights_stay_outlined,
            label: 'Night Usage',
            value: summary.nightUsage ? 'Detected' : 'None',
            valueColor: summary.nightUsage ? Colors.orange.shade700 : Colors.green.shade700,
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          _DetailRow(
            icon: Icons.trending_down_rounded,
            label: 'Distraction Ratio',
            value: '$distractionPct%',
            valueColor: distractionColor,
          ),
          Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          _DetailRow(
            icon: Icons.apps_rounded,
            label: 'Top Distractor',
            value: summary.topDistractingApp ?? 'None',
            valueColor: summary.topDistractingApp != null
                ? Colors.red.shade700
                : Colors.green.shade700,
          ),
        ],
      ),
    );
  }

  String _formatAverage(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 1) return '${seconds.round()}s';
    return '${minutes}m';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      title: Text(label,
          style: TextStyle(fontSize: 14, color: cs.onSurface)),
      trailing: Text(
        value,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 14,
          color: valueColor ?? cs.onSurface,
        ),
      ),
    );
  }
}
