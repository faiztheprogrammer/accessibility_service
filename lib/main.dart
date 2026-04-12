import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AccessibilityApp());
}

class AccessibilityApp extends StatelessWidget {
  const AccessibilityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'App Content Monitor',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MonitorScreen(),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  List<Map<String, dynamic>> _logEntries = [];
  bool _isServiceActive = false;
  String _currentApp = 'None';
  String _lastContent = '';
  
  late MethodChannel _platformChannel;

  @override
  void initState() {
    super.initState();
    _platformChannel = const MethodChannel('com.example.accessibility_service/monitor');
    _initChannel();
  }

  void _initChannel() {
    _platformChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'service_status':
          final status = call.arguments['status'];
          final isRunning = call.arguments['isRunning'] ?? false;
          
          setState(() {
            _isServiceActive = isRunning;
          });
          
          _addLog('Service', 'Status: $status');
          break;
        
        case 'content_extracted':
          final package = call.arguments['package'] ?? 'unknown';
          final text = call.arguments['text'] ?? '';
          final timestamp = call.arguments['timestamp'] ?? 0;
          
          if (text.isNotEmpty) {
            setState(() {
              _currentApp = _getAppName(package);
              _lastContent = text;
            });
            
            _addLog(_currentApp, _truncateText(text));
            
            // Analyze content for productivity
            _analyzeContent(text);
          }
          break;
      }
    });
  }

  String _getAppName(String package) {
    final appNames = {
      'com.google.android.gm': 'Gmail',
      'com.facebook.katana': 'Facebook',
      'com.linkedin.android': 'LinkedIn',
      'com.whatsapp': 'WhatsApp',
      'com.instagram.android': 'Instagram',
      'com.google.android.youtube': 'YouTube',
    };
    return appNames[package] ?? package;
  }

  String _truncateText(String text) {
    const maxLength = 80;
    return text.length > maxLength ? '${text.substring(0, maxLength)}...' : text;
  }

  void _addLog(String app, String content) {
    setState(() {
      _logEntries.insert(0, {
        'app': app,
        'content': content,
        'time': DateTime.now(),
      });
      
      if (_logEntries.length > 50) {
        _logEntries.removeLast();
      }
    });
  }

  void _analyzeContent(String text) {
    // Simple content analysis (you'll replace this with your AI model)
    final keywords = ['work', 'job', 'project', 'meeting', 'deadline', 'code'];
    final textLower = text.toLowerCase();
    
    bool isProductive = keywords.any((keyword) => textLower.contains(keyword));
    
    if (isProductive) {
      _showNotification('✅ Productive Content', 'Keep it up!');
    } else {
      _showNotification('⚠️ Potential Distraction', 'Consider focusing on work');
    }
  }

  void _showNotification(String title, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(message),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _clearLogs() {
    setState(() {
      _logEntries.clear();
    });
  }

  void _showEnableInstructions() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable Accessibility Service'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To enable monitoring:'),
            SizedBox(height: 10),
            Text('1. Go to Settings > Accessibility'),
            Text('2. Tap "Downloaded Services"'),
            Text('3. Enable "App Content Monitor"'),
            SizedBox(height: 10),
            Text('The service will monitor:'),
            Text('• Gmail, Facebook, LinkedIn'),
            Text('• WhatsApp, Instagram'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Content Monitor'),
        actions: [
          IconButton(
            icon: Icon(_isServiceActive ? Icons.check_circle : Icons.error),
            color: _isServiceActive ? Colors.green : Colors.orange,
            onPressed: _showEnableInstructions,
            tooltip: 'Service Status',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: _clearLogs,
            tooltip: 'Clear Logs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Status Card
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _isServiceActive ? Icons.check_circle : Icons.warning,
                    color: _isServiceActive ? Colors.green : Colors.orange,
                    size: 40,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isServiceActive ? 'Monitoring Active' : 'Service Not Active',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Current App: $_currentApp',
                          style: TextStyle(
                            color: Colors.grey[600],
                          ),
                        ),
                        if (_lastContent.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _truncateText(_lastContent),
                            style: const TextStyle(fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _showEnableInstructions,
                    child: const Text('Enable'),
                  ),
                ],
              ),
            ),
          ),

          // Logs Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.blue[50],
            child: Row(
              children: [
                const Icon(Icons.history, size: 20),
                const SizedBox(width: 8),
                const Text('Activity Log', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${_logEntries.length} entries'),
              ],
            ),
          ),

          // Logs List
          Expanded(
            child: _logEntries.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.list, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text('No activity recorded yet'),
                        SizedBox(height: 8),
                        Text(
                          'Open Gmail, Facebook, or other apps\n to see content extraction',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _logEntries.length,
                    itemBuilder: (context, index) {
                      final entry = _logEntries[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _getAppColor(entry['app']),
                          child: Text(
                            entry['app'][0],
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(entry['app']),
                        subtitle: Text(entry['content']),
                        trailing: Text(
                          _formatTime(entry['time']),
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                        dense: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _getAppColor(String app) {
    final colors = {
      'Gmail': Colors.red,
      'Facebook': Colors.blue,
      'LinkedIn': Colors.blue[800]!,
      'WhatsApp': Colors.green,
      'Instagram': Colors.pink,
      'YouTube': Colors.red[700]!,
    };
    return colors[app] ?? Colors.grey;
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    
    if (difference.inSeconds < 60) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }
}