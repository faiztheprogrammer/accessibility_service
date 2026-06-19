import 'package:flutter/material.dart';
import '../services/db_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final TextEditingController _goalController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _savedSuccess = false;
  String? _errorMessage;

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
  }

  @override
  void dispose() {
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final profile = await DatabaseService().getUserProfile();
    if (!mounted) return;
    setState(() {
      _goalController.text = profile?['focus_goal']?.toString() ?? '';
      _isLoading = false;
    });
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

    await DatabaseService().upsertUserProfile(goal);
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
                // Header card
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
                const SizedBox(height: 24),
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
                    hintText: 'e.g. Flutter Developer, Medical Student…',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.edit_outlined),
                    filled: true,
                    fillColor: cs.surface,
                  ),
                ),
                const SizedBox(height: 12),
                // Quick-select suggestions
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
                    message: 'Goal saved — evaluations will now use this context.',
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
              ],
            ),
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
                  color: color,
                  fontWeight: FontWeight.w500,
                  fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
