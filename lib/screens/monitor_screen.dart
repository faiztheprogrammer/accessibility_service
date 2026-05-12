import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/db_service.dart';
import '../services/api_service.dart';

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
  bool _isOfflineMode = false;
  
  // Banner state
  String _bannerTitle = 'Evaluating Content...';
  String _bannerMessage = 'Watching for distractions';
  Color _bannerColor = Colors.grey;
  
  // DB session tracking
  int? _currentSessionId;
  String _lastAppPackage = '';
  
  late MethodChannel _platformChannel;

  @override
  void initState() {
    super.initState();
    _platformChannel = const MethodChannel('com.example.accessibility_service/monitor');
    _initChannel();
    _loadHistoricalData();
  }

  Future<void> _loadHistoricalData() async {
    final logs = await DatabaseService().getRecentContent();
    setState(() {
      _logEntries = logs.map((row) => {
        'app': row['app_name'],
        'content': row['title'] ?? row['extracted_text'],
        'time': DateTime.parse(row['timestamp']),
        'isProductive': row['is_productive'] == 1,
        'relevanceScore': row['relevance_score'],
        'source': row['source'] ?? 'api',
      }).toList();
    });
  }

  void _initChannel() {
    _platformChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'service_status':
          final statusData = call.arguments;
          final isRunning = statusData['isRunning'] ?? false;
          setState(() { _isServiceActive = isRunning; });
          break;
        
        case 'content_extracted':
          final package = call.arguments['package'] ?? 'unknown';
          final text = call.arguments['text'] ?? '';
          final title = call.arguments['title'] ?? '';
          final channel = call.arguments['channel'] ?? '';
          
          if (text.isNotEmpty || title.isNotEmpty) {
            final displayTitle = title.isNotEmpty ? title : text;
            
            setState(() {
              _currentApp = _getAppName(package);
              _lastContent = displayTitle;
              _bannerTitle = 'Analyzing: $displayTitle';
              _bannerColor = Colors.blueGrey;
            });
            
            if (package != _lastAppPackage || _currentSessionId == null) {
              if (_currentSessionId != null) {
                DatabaseService().updateSessionEndTime(_currentSessionId!);
              }
              _lastAppPackage = package;
              _currentSessionId = await DatabaseService().insertSession(_currentApp);
            }
            
            final contentId = await DatabaseService().insertContent(
              _currentSessionId!,
              title,
              channel,
              text,
            );
            
            _analyzeContent(title, channel, text, contentId);
          }
          break;
      }
    });
  }

  String _getAppName(String package) {
    final appNames = {
      'com.facebook.katana': 'Facebook',
      'com.twitter.android': 'Twitter / X',
      'com.linkedin.android': 'LinkedIn',
      'com.instagram.android': 'Instagram',
      'com.google.android.youtube': 'YouTube',
    };
    return appNames[package] ?? package;
  }

  void _addLog(String app, String content, bool? isProductive, {String? source}) {
    setState(() {
      _logEntries.insert(0, {
        'app': app,
        'content': content,
        'time': DateTime.now(),
        'isProductive': isProductive,
        'source': source,
      });
      if (_logEntries.length > 50) _logEntries.removeLast();
    });
  }

  Future<void> _analyzeContent(String title, String channel, String text, int contentId) async {
    final result = await ApiService.evaluateContent(
      title: title,
      channel: channel,
      extractedText: text,
    );
    
    bool isProductive = false;
    double relevanceScore = 0.0;
    String source = 'api';
    
    if (result != null) {
      isProductive = result['is_productive'] ?? false;
      relevanceScore = (result['relevance_score'] as num).toDouble();
      source = result['source'] ?? 'api';
    }
    
    await DatabaseService().insertVerdict(contentId, relevanceScore, isProductive);
    
    final displayTitle = title.isNotEmpty ? title : (text.length > 50 ? text.substring(0, 50) : text);
    _addLog(_currentApp, displayTitle, isProductive, source: source);
    
    setState(() {
      _isOfflineMode = (source == 'local_backup');
      if (isProductive) {
        _bannerTitle = 'Productive Content (${(relevanceScore * 100).toInt()}%)';
        _bannerMessage = 'Keep up the good work!';
        _bannerColor = Colors.green;
      } else {
        _bannerTitle = 'Distraction Detected!';
        _bannerMessage = 'Consider returning to your goals';
        _bannerColor = Colors.redAccent;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FYP Content Monitor'),
        bottom: _isOfflineMode ? PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Container(
            color: Colors.orange[100],
            width: double.infinity,
            child: const Text('⚠️ Using Offline Scoring (Laptop Disconnected)', 
              textAlign: TextAlign.center, 
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ) : null,
        actions: [
          IconButton(
            icon: Icon(_isServiceActive ? Icons.check_circle : Icons.error),
            color: _isServiceActive ? Colors.green : Colors.orange,
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(() => _logEntries.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _isServiceActive ? Icons.shield : Icons.shield_outlined,
                    color: _isServiceActive ? Colors.green : Colors.red,
                    size: 40,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_isServiceActive ? 'Background Protection Active' : 'Protection Disabled',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('Current App: $_currentApp', style: TextStyle(color: Colors.grey[600])),
                        if (_lastContent.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(_lastContent, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.blue[50],
            child: Row(
              children: [
                const Icon(Icons.history, size: 20),
                const SizedBox(width: 8),
                const Text('Live Activity Log', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${_logEntries.length} items'),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _logEntries.length,
              itemBuilder: (context, index) {
                final entry = _logEntries[index];
                final isProductive = entry['isProductive'] == true;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isProductive ? Colors.green[100] : Colors.red[100],
                    child: Icon(
                      isProductive ? Icons.check : Icons.warning,
                      color: isProductive ? Colors.green : Colors.red,
                      size: 20,
                    ),
                  ),
                  title: Text(entry['app'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(entry['content']),
                  trailing: entry['source'] == 'local_backup' 
                    ? const Icon(Icons.cloud_off, size: 14, color: Colors.grey)
                    : null,
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        color: _bannerColor,
        padding: const EdgeInsets.all(16.0),
        child: SafeArea(
          child: Row(
            children: [
              const Icon(Icons.notifications_active, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_bannerTitle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(_bannerMessage, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getAppColor(String app) {
    if (app == 'YouTube') return Colors.red;
    if (app == 'Facebook') return Colors.blue;
    return Colors.grey;
  }
}
