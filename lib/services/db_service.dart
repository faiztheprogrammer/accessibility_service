import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;

  factory DatabaseService() => _instance;

  DatabaseService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'content_monitor.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createCoreTables(db);
        await _createFypTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createFypTables(db);
        }
      },
    );
  }

  Future<void> _createCoreTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS AppSessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        app_name TEXT NOT NULL,
        start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        end_time TIMESTAMP
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS Content (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER,
        title TEXT,
        channel TEXT,
        extracted_text TEXT,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (session_id) REFERENCES AppSessions (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS Verdicts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_id INTEGER,
        relevance_score REAL,
        is_productive BOOLEAN,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (content_id) REFERENCES Content (id)
      )
    ''');
  }

  Future<void> _createFypTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS User_Profile (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL UNIQUE,
        focus_goal TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS BehavioralMetrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        avg_session_duration REAL DEFAULT 0,
        night_usage INTEGER DEFAULT 0,
        session_frequency INTEGER DEFAULT 0,
        total_time_today INTEGER DEFAULT 0,
        app_category TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS Intervention (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER,
        tier_level TEXT NOT NULL,
        shown_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES AppSessions (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS CacheStore (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        content_hash TEXT NOT NULL UNIQUE,
        last_relevance_score REAL NOT NULL,
        last_label TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');
  }

  // Session Management
  Future<int> insertSession(String appName) async {
    final db = await database;
    return await db.insert('AppSessions', {'app_name': appName});
  }

  Future<void> updateSessionEndTime(int sessionId) async {
    final db = await database;
    await db.update(
      'AppSessions',
      {'end_time': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  // Content Logging
  Future<int> insertContent(int sessionId, String title, String channel, String text) async {
    final db = await database;
    return await db.insert('Content', {
      'session_id': sessionId,
      'title': title,
      'channel': channel,
      'extracted_text': text,
    });
  }

  // Verdict Logging
  Future<void> insertVerdict(int contentId, double score, bool isProductive) async {
    final db = await database;
    await db.insert('Verdicts', {
      'content_id': contentId,
      'relevance_score': score,
      'is_productive': isProductive ? 1 : 0,
    });
  }

  // Querying for UI
  Future<List<Map<String, dynamic>>> getRecentContent() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT c.*, v.relevance_score, v.is_productive, s.app_name
      FROM Content c
      LEFT JOIN Verdicts v ON c.id = v.content_id
      JOIN AppSessions s ON c.session_id = s.id
      ORDER BY c.timestamp DESC
      LIMIT 50
    ''');
  }

  Future<void> upsertUserProfile(String focusGoal, {String userId = 'default_user'}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    await db.insert(
      'User_Profile',
      {
        'user_id': userId,
        'focus_goal': focusGoal.trim(),
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getUserProfile({String userId = 'default_user'}) async {
    final db = await database;
    final rows = await db.query(
      'User_Profile',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<String> getFocusGoal({String fallback = 'General Productivity'}) async {
    final profile = await getUserProfile();
    final goal = profile?['focus_goal']?.toString().trim();
    return goal == null || goal.isEmpty ? fallback : goal;
  }

  Future<int> insertBehavioralMetrics({
    required double avgSessionDuration,
    required bool nightUsage,
    required int sessionFrequency,
    required int totalTimeToday,
    required String appCategory,
  }) async {
    final db = await database;
    return await db.insert('BehavioralMetrics', {
      'avg_session_duration': avgSessionDuration,
      'night_usage': nightUsage ? 1 : 0,
      'session_frequency': sessionFrequency,
      'total_time_today': totalTimeToday,
      'app_category': appCategory,
    });
  }

  Future<int> insertIntervention(int sessionId, String tierLevel) async {
    final db = await database;
    return await db.insert('Intervention', {
      'session_id': sessionId,
      'tier_level': tierLevel,
      'shown_at': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>?> getCachedVerdict(String contentHash) async {
    final db = await database;
    final rows = await db.query(
      'CacheStore',
      where: 'content_hash = ?',
      whereArgs: [contentHash],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> upsertCachedVerdict({
    required String contentHash,
    required double relevanceScore,
    required String label,
  }) async {
    final db = await database;
    await db.insert(
      'CacheStore',
      {
        'content_hash': contentHash,
        'last_relevance_score': relevanceScore,
        'last_label': label,
        'cached_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
