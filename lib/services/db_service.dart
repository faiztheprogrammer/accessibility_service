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
      version: 1,
      onCreate: (db, version) async {
        // Tier 2: Relational Tables for AppSessions, Content, and Verdicts
        await db.execute('''
          CREATE TABLE AppSessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_name TEXT NOT NULL,
            start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            end_time TIMESTAMP
          )
        ''');

        await db.execute('''
          CREATE TABLE Content (
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
          CREATE TABLE Verdicts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_id INTEGER,
            relevance_score REAL,
            is_productive BOOLEAN,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (content_id) REFERENCES Content (id)
          )
        ''');
      },
    );
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
}
