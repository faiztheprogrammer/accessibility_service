import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../services/behavior_analytics_service.dart';

// ── Range selector ────────────────────────────────────────────────────────────

enum _Range { today, week, month, custom }

extension _RangeLabel on _Range {
  String get label {
    switch (this) {
      case _Range.today:
        return 'Today';
      case _Range.week:
        return 'Last 7 Days';
      case _Range.month:
        return 'Last 30 Days';
      case _Range.custom:
        return 'Custom';
    }
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _analytics = BehaviorAnalyticsService();

  _Range _range = _Range.today;
  DateTimeRange? _customRange;

  // Resolved from/to for current selection
  DateTime get _from {
    final now = DateTime.now();
    switch (_range) {
      case _Range.today:
        return DateTime(now.year, now.month, now.day);
      case _Range.week:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
      case _Range.month:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 29));
      case _Range.custom:
        return _customRange?.start ?? DateTime(now.year, now.month, now.day);
    }
  }

  DateTime get _to {
    final now = DateTime.now();
    return _customRange != null && _range == _Range.custom
        ? _customRange!.end
        : DateTime(now.year, now.month, now.day);
  }

  late Future<_DashboardData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_DashboardData> _load() async {
    if (_range == _Range.today) {
      final summary =
          await _analytics.calculateAndPersistDailySummary(date: _from);
      return _DashboardData(today: summary, history: [summary]);
    }

    // For ranges: recalculate today so it's fresh, fetch rest from store
    final todaySummary =
        await _analytics.calculateAndPersistDailySummary();
    final history = await _analytics.getStoredSummariesForRange(
      from: _from,
      to: _to,
    );
    // Merge: replace today's stored entry with live-calculated one
    final todayKey = todaySummary.metricDate;
    final merged = [
      ...history.where((s) => s.metricDate != todayKey),
      todaySummary,
    ]..sort((a, b) => a.metricDate.compareTo(b.metricDate));

    return _DashboardData(today: todaySummary, history: merged);
  }

  void _refresh() {
    final next = _load();
    setState(() => _dataFuture = next);
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      initialDateRange: _customRange ??
          DateTimeRange(
            start: now.subtract(const Duration(days: 6)),
            end: now,
          ),
      builder: (context, child) => Theme(
        data: Theme.of(context),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customRange = picked;
      _range = _Range.custom;
      _dataFuture = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title:
            const Text('Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Date range selector ──────────────────────────────────────────
          _RangeSelector(
            selected: _range,
            onSelect: (r) {
              if (r == _Range.custom) {
                _pickCustomRange();
                return;
              }
              setState(() {
                _range = r;
                _customRange = null;
                _dataFuture = _load();
              });
            },
          ),

          // ── Content ──────────────────────────────────────────────────────
          Expanded(
            child: FutureBuilder<_DashboardData>(
              future: _dataFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return _ErrorState(error: '${snapshot.error}');
                }

                final data = snapshot.data;
                if (data == null || data.today.totalVerdicts == 0) {
                  return const _EmptyState();
                }

                return RefreshIndicator(
                  onRefresh: () async => _refresh(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      // Focus score card (always today)
                      _FocusScorePanel(summary: data.today),
                      const SizedBox(height: 16),

                      _SectionLabel(
                        label: _range == _Range.today
                            ? "Today's Activity"
                            : 'Activity — ${_range.label}',
                      ),
                      const SizedBox(height: 10),
                      _MetricsGrid(history: data.history, range: _range),
                      const SizedBox(height: 16),

                      // ── Pie chart ────────────────────────────────────────
                      _SectionLabel(
                        label: _range == _Range.today
                            ? 'Content Breakdown'
                            : 'Content Breakdown — ${_range.label}',
                      ),
                      const SizedBox(height: 10),
                      _PieChartCard(history: data.history),
                      const SizedBox(height: 16),

                      // ── Line chart (only meaningful for multi-day ranges)
                      if (data.history.length > 1) ...[
                        _SectionLabel(
                          label: 'Focus Score Trend — ${_range.label}',
                        ),
                        const SizedBox(height: 10),
                        _LineChartCard(history: data.history),
                        const SizedBox(height: 16),
                      ],

                      _SectionLabel(label: 'Details'),
                      const SizedBox(height: 10),
                      _DetailPanel(summary: data.today),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── Data holder ───────────────────────────────────────────────────────────────

class _DashboardData {
  final BehaviorSummary today;
  final List<BehaviorSummary> history;
  const _DashboardData({required this.today, required this.history});
}

// ── Range selector widget ─────────────────────────────────────────────────────

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selected, required this.onSelect});

  final _Range selected;
  final void Function(_Range) onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _Range.values.map((r) {
            final isSelected = r == selected;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(r.label),
                selected: isSelected,
                onSelected: (_) => onSelect(r),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                ),
                selectedColor: cs.primary,
                backgroundColor: cs.surfaceContainerHighest,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ── Pie chart card ────────────────────────────────────────────────────────────

class _PieChartCard extends StatefulWidget {
  const _PieChartCard({required this.history});
  final List<BehaviorSummary> history;

  @override
  State<_PieChartCard> createState() => _PieChartCardState();
}

class _PieChartCardState extends State<_PieChartCard> {
  int _touchedIndex = -1;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final productive =
        widget.history.fold<int>(0, (s, h) => s + h.productiveCount);
    final distracting =
        widget.history.fold<int>(0, (s, h) => s + h.unproductiveCount);
    final total = productive + distracting;

    if (total == 0) {
      return const SizedBox.shrink();
    }

    final prodPct = (productive / total * 100).round();
    final distPct = 100 - prodPct;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      setState(() {
                        if (!event.isInterestedForInteractions ||
                            response == null ||
                            response.touchedSection == null) {
                          _touchedIndex = -1;
                          return;
                        }
                        _touchedIndex =
                            response.touchedSection!.touchedSectionIndex;
                      });
                    },
                  ),
                  borderData: FlBorderData(show: false),
                  sectionsSpace: 3,
                  centerSpaceRadius: 48,
                  sections: [
                    PieChartSectionData(
                      value: productive.toDouble(),
                      color: Colors.green.shade600,
                      title: '$prodPct%',
                      radius: _touchedIndex == 0 ? 56 : 48,
                      titleStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                    PieChartSectionData(
                      value: distracting.toDouble(),
                      color: Colors.red.shade500,
                      title: '$distPct%',
                      radius: _touchedIndex == 1 ? 56 : 48,
                      titleStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Legend(color: Colors.green.shade600, label: 'Productive ($productive)'),
                const SizedBox(width: 24),
                _Legend(color: Colors.red.shade500, label: 'Distracting ($distracting)'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
      ],
    );
  }
}

// ── Line chart card ───────────────────────────────────────────────────────────

class _LineChartCard extends StatelessWidget {
  const _LineChartCard({required this.history});
  final List<BehaviorSummary> history;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final spots = history.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value.focusScore * 100);
    }).toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  minY: 0,
                  maxY: 100,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: 25,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: cs.outlineVariant.withValues(alpha: 0.4),
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 25,
                        reservedSize: 32,
                        getTitlesWidget: (value, meta) => Text(
                          '${value.toInt()}',
                          style: TextStyle(
                              fontSize: 10, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: _labelInterval(history.length).toDouble(),
                        reservedSize: 24,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx < 0 || idx >= history.length) {
                            return const SizedBox.shrink();
                          }
                          final date = history[idx].metricDate;
                          final parts = date.split('-');
                          final label = parts.length == 3
                              ? '${parts[2]}/${parts[1]}'
                              : date;
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              label,
                              style: TextStyle(
                                  fontSize: 9, color: cs.onSurfaceVariant),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) =>
                          cs.surfaceContainerHighest,
                      getTooltipItems: (spots) => spots
                          .map((s) => LineTooltipItem(
                                '${s.y.round()}%',
                                TextStyle(
                                    color: cs.primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ))
                          .toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      curveSmoothness: 0.35,
                      color: cs.primary,
                      barWidth: 2.5,
                      dotData: FlDotData(
                        show: history.length <= 14,
                        getDotPainter: (spot, percent, bar, index) =>
                            FlDotCirclePainter(
                          radius: 3.5,
                          color: cs.primary,
                          strokeColor: cs.surface,
                          strokeWidth: 1.5,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        color: cs.primary.withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _labelInterval(int count) {
    if (count <= 7) return 1;
    if (count <= 14) return 2;
    return 5;
  }
}

// ── Shared section label ──────────────────────────────────────────────────────

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

// ── Focus score panel ─────────────────────────────────────────────────────────

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

// ── Metrics grid ──────────────────────────────────────────────────────────────

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.history, required this.range});
  final List<BehaviorSummary> history;
  final _Range range;

  @override
  Widget build(BuildContext context) {
    final totalTime =
        history.fold<int>(0, (s, h) => s + h.totalTimeToday);
    final totalSessions =
        history.fold<int>(0, (s, h) => s + h.sessionFrequency);
    final totalProductive =
        history.fold<int>(0, (s, h) => s + h.productiveCount);
    final totalDistracting =
        history.fold<int>(0, (s, h) => s + h.unproductiveCount);

    final timeLabel = switch (range) {
      _Range.today => 'Time Today',
      _Range.week => 'Time (7 Days)',
      _Range.month => 'Time (30 Days)',
      _Range.custom => 'Time (Range)',
    };

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
          label: timeLabel,
          value: _formatDuration(totalTime),
          color: Theme.of(context).colorScheme.primary,
        ),
        _MetricTile(
          icon: Icons.repeat_rounded,
          label: 'Sessions',
          value: totalSessions.toString(),
          color: Theme.of(context).colorScheme.primary,
        ),
        _MetricTile(
          icon: Icons.check_circle_outline_rounded,
          label: 'Productive',
          value: totalProductive.toString(),
          color: Colors.green.shade700,
        ),
        _MetricTile(
          icon: Icons.warning_amber_rounded,
          label: 'Distracting',
          value: totalDistracting.toString(),
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

// ── Detail panel ──────────────────────────────────────────────────────────────

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
          Divider(
              height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          _DetailRow(
            icon: Icons.nights_stay_outlined,
            label: 'Night Usage',
            value: summary.nightUsage ? 'Detected' : 'None',
            valueColor: summary.nightUsage
                ? Colors.orange.shade700
                : Colors.green.shade700,
          ),
          Divider(
              height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
          _DetailRow(
            icon: Icons.trending_down_rounded,
            label: 'Distraction Ratio',
            value: '$distractionPct%',
            valueColor: distractionColor,
          ),
          Divider(
              height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
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
      title: Text(label, style: TextStyle(fontSize: 14, color: cs.onSurface)),
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

// ── Empty / error states ──────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bar_chart_rounded, size: 64, color: cs.outlineVariant),
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
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
            const SizedBox(height: 16),
            Text(
              'Could not load dashboard data.',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
