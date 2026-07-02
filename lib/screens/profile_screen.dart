import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/db_service.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _channel =
      MethodChannel('com.example.accessibility_service/monitor');

  final TextEditingController _goalController = TextEditingController();
  final TextEditingController _nudgeMessageController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _savedSuccess = false;
  String? _errorMessage;
  bool _reelsBlockEnabled = true;
  bool _nudgeEnabled = true;
  TimeOfDay _nudgeTime = const TimeOfDay(hour: 8, minute: 0);
  bool _nudgeTestSent = false;

  static const _suggestions = [
    'Flutter Developer',
    'Medical Student',
    'Data Scientist',
    'Filmmaker',
    'Graphic Designer',
    'Software Engineer',
    'Business Analyst',
    'UI/UX Designer',
  ];

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadReelsBlockSetting();
    _loadNudgeSettings();
  }

  @override
  void dispose() {
    _goalController.dispose();
    _nudgeMessageController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final userId = await AuthService().currentUserId();
    final profile = await DatabaseService().getUserProfile(userId: userId);
    if (!mounted) return;
    setState(() {
      _goalController.text = profile?['focus_goal']?.toString() ?? '';
      _isLoading = false;
    });
  }

  Future<void> _loadReelsBlockSetting() async {
    try {
      final enabled =
          await _channel.invokeMethod<bool>('get_reels_block_enabled');
      if (!mounted) return;
      setState(() => _reelsBlockEnabled = enabled ?? true);
    } on PlatformException {
      // Default stays true
    }
  }

  Future<void> _loadNudgeSettings() async {
    try {
      final enabled = await _channel.invokeMethod<bool>('get_nudge_enabled');
      final timeMap = await _channel.invokeMethod<Map>('get_nudge_time');
      final msg = await _channel.invokeMethod<String>('get_nudge_message');
      if (!mounted) return;
      setState(() {
        _nudgeEnabled = enabled ?? true;
        if (timeMap != null) {
          _nudgeTime = TimeOfDay(
            hour: (timeMap['hour'] as int?) ?? 8,
            minute: (timeMap['minute'] as int?) ?? 0,
          );
        }
        _nudgeMessageController.text = msg ?? '';
      });
    } on PlatformException {
      // Defaults stay
    }
  }

  Future<void> _setReelsBlock(bool enabled) async {
    setState(() => _reelsBlockEnabled = enabled);
    try {
      await _channel.invokeMethod('set_reels_block_enabled', enabled);
    } on PlatformException {
      // Best-effort; state already updated optimistically
    }
  }

  Future<void> _setNudgeEnabled(bool enabled) async {
    setState(() => _nudgeEnabled = enabled);
    try {
      await _channel.invokeMethod('set_nudge_enabled', enabled);
    } on PlatformException {
      // Best-effort
    }
  }

  Future<void> _pickNudgeTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _nudgeTime,
    );
    if (picked == null || !mounted) return;
    setState(() => _nudgeTime = picked);
    try {
      await _channel.invokeMethod('set_nudge_time', {
        'hour': picked.hour,
        'minute': picked.minute,
      });
    } on PlatformException {
      // Best-effort
    }
  }

  Future<void> _saveNudgeMessage() async {
    try {
      await _channel.invokeMethod('set_nudge_message', _nudgeMessageController.text.trim());
    } on PlatformException {
      // Best-effort
    }
  }

  Future<void> _testNudge() async {
    try {
      await _saveNudgeMessage();
      await _channel.invokeMethod('test_morning_nudge');
      if (!mounted) return;
      setState(() => _nudgeTestSent = true);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _nudgeTestSent = false);
      });
    } on PlatformException {
      // Silently ignore
    }
  }

  Future<void> _saveGoal() async {
    final goal = _goalController.text.trim();
    if (goal.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter a career goal.';
        _savedSuccess = false;
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _savedSuccess = false;
    });

    final userId = await AuthService().currentUserId();
    await DatabaseService().upsertUserProfile(goal, userId: userId);
    // Mirror goal to SharedPrefs so the morning nudge receiver can read it
    // without opening SQLite from a BroadcastReceiver context.
    try {
      await _channel.invokeMethod('set_focus_goal_cache', goal);
    } on PlatformException {
      // Best-effort — nudge will just skip if goal isn't cached yet
    }
    if (!mounted) return;

    setState(() {
      _isSaving = false;
      _savedSuccess = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: const Text('Goal Profile',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Career goal header ─────────────────────────────────────
                Card(
                  elevation: 0,
                  color: cs.primaryContainer.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.track_changes_rounded,
                            color: cs.primary, size: 32),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your Career Goal',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'FocusGuard uses this to judge whether the content you watch aligns with your aspirations.',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Goal text field ────────────────────────────────────────
                TextField(
                  controller: _goalController,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) {
                    if (_savedSuccess || _errorMessage != null) {
                      setState(() {
                        _savedSuccess = false;
                        _errorMessage = null;
                      });
                    }
                  },
                  onSubmitted: (_) => _saveGoal(),
                  decoration: InputDecoration(
                    labelText: 'Career goal',
                    hintText: 'Type anything — e.g. Cardiologist, Game Dev…',
                    helperText: 'Or pick a suggestion below',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.edit_outlined),
                    filled: true,
                    fillColor: cs.surface,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Quick-select suggestions ───────────────────────────────
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _suggestions.map((s) {
                    final selected = _goalController.text.trim() == s;
                    return FilterChip(
                      label: Text(s),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _goalController.text = s;
                          _savedSuccess = false;
                          _errorMessage = null;
                        });
                      },
                      labelStyle: TextStyle(
                        fontSize: 12,
                        color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                      ),
                      selectedColor: cs.primary,
                      checkmarkColor: cs.onPrimary,
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                // ── Save button ────────────────────────────────────────────
                FilledButton.icon(
                  onPressed: _isSaving ? null : _saveGoal,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_rounded),
                  label: Text(_isSaving ? 'Saving…' : 'Save Goal'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                if (_savedSuccess) ...[
                  const SizedBox(height: 16),
                  _StatusMessage(
                    icon: Icons.check_circle_rounded,
                    message:
                        'Goal saved — evaluations will now use this context.',
                    color: Colors.green.shade700,
                    bgColor: Colors.green.withValues(alpha: 0.08),
                  ),
                ],
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  _StatusMessage(
                    icon: Icons.error_outline_rounded,
                    message: _errorMessage!,
                    color: Colors.red.shade700,
                    bgColor: Colors.red.withValues(alpha: 0.08),
                  ),
                ],

                // ── Notifications ──────────────────────────────────────────
                const SizedBox(height: 32),
                Text(
                  'NOTIFICATIONS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: cs.outline,
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      // Toggle
                      SwitchListTile(
                        value: _nudgeEnabled,
                        onChanged: _setNudgeEnabled,
                        secondary: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: _nudgeEnabled
                                ? cs.primaryContainer
                                : cs.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.wb_sunny_rounded,
                            size: 22,
                            color: _nudgeEnabled
                                ? cs.primary
                                : cs.outline,
                          ),
                        ),
                        title: const Text('Daily Focus Reminder',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text(
                          _nudgeEnabled
                              ? 'Morning nudge with your focus goal'
                              : 'Morning reminder is off',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(14),
                            topRight: Radius.circular(14),
                          ),
                        ),
                      ),
                      if (_nudgeEnabled) ...[
                        Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: cs.outlineVariant.withValues(alpha: 0.4)),
                        // Time picker row
                        ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              shape: BoxShape.circle,
                            ),
                            child:
                                Icon(Icons.access_time_rounded, size: 22, color: cs.primary),
                          ),
                          title: const Text('Reminder time',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 14)),
                          subtitle: Text(
                            _nudgeTime.format(context),
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                          trailing: TextButton(
                            onPressed: _pickNudgeTime,
                            child: const Text('Change'),
                          ),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                        Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: cs.outlineVariant.withValues(alpha: 0.4)),
                        // Custom reminder message
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: TextField(
                            controller: _nudgeMessageController,
                            maxLength: 80,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _saveNudgeMessage(),
                            onEditingComplete: _saveNudgeMessage,
                            decoration: InputDecoration(
                              labelText: 'Reminder message',
                              hintText: 'Good morning! Stay focused today.',
                              helperText: 'Leave blank to use the default message',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              prefixIcon: const Icon(Icons.edit_notifications_rounded),
                              filled: true,
                              fillColor: cs.surface,
                              counterStyle: TextStyle(fontSize: 11, color: cs.outline),
                            ),
                          ),
                        ),
                        Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: cs.outlineVariant.withValues(alpha: 0.4)),
                        // Test button row
                        ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _nudgeTestSent
                                  ? Colors.green.withValues(alpha: 0.12)
                                  : cs.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _nudgeTestSent
                                  ? Icons.check_rounded
                                  : Icons.send_rounded,
                              size: 20,
                              color: _nudgeTestSent
                                  ? Colors.green.shade700
                                  : cs.outline,
                            ),
                          ),
                          title: Text(
                            _nudgeTestSent
                                ? 'Notification sent!'
                                : 'Send test notification',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: _nudgeTestSent
                                  ? Colors.green.shade700
                                  : cs.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            'See what the morning reminder looks like',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                          ),
                          onTap: _nudgeTestSent ? null : _testNudge,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(14),
                              bottomRight: Radius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                // ── Blocking settings ──────────────────────────────────────
                const SizedBox(height: 32),
                Text(
                  'BLOCKING',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: cs.outline,
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: SwitchListTile(
                    value: _reelsBlockEnabled,
                    onChanged: _setReelsBlock,
                    secondary: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _reelsBlockEnabled
                            ? Colors.red.withValues(alpha: 0.10)
                            : cs.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_circle_outline_rounded,
                        size: 22,
                        color: _reelsBlockEnabled
                            ? Colors.red.shade700
                            : cs.outline,
                      ),
                    ),
                    title: const Text('Block Instagram Reels',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    subtitle: Text(
                      _reelsBlockEnabled
                          ? 'Overlay shown when Reels tab is active'
                          : 'Reels are allowed — overlay is off',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    activeThumbColor: Colors.red.shade700,
                    activeTrackColor: Colors.red.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),

                // ── Account ────────────────────────────────────────────────
                const SizedBox(height: 32),
                Text(
                  'ACCOUNT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                    color: cs.outline,
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.logout_rounded,
                          size: 20, color: Colors.red.shade700),
                    ),
                    title: const Text('Sign Out',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Colors.red)),
                    subtitle: Text('You will be returned to the login screen',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    onTap: _signOut,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AuthService().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({
    required this.icon,
    required this.message,
    required this.color,
    required this.bgColor,
  });

  final IconData icon;
  final String message;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w500, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
