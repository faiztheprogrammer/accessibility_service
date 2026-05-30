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
  String? _statusMessage;

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
        _statusMessage = 'Please enter a career goal.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _statusMessage = null;
    });

    await DatabaseService().upsertUserProfile(goal);
    if (!mounted) return;

    setState(() {
      _isSaving = false;
      _statusMessage = 'Goal saved successfully.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Goal Profile'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _goalController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Career goal',
                    hintText: 'Flutter Developer, Filmmaker, Medical Student',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saveGoal(),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _isSaving ? null : _saveGoal,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_isSaving ? 'Saving' : 'Save Goal'),
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _statusMessage!,
                    style: TextStyle(
                      color: _statusMessage == 'Goal saved successfully.'
                          ? Colors.green
                          : Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
