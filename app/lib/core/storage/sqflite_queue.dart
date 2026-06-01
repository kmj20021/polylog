// 오프라인 큐잉 스켈레톤 — ADR-011. 실구현은 WBS 1.4.3에서.
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class SqfliteQueue {
  static Database? _db;

  static Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'polylog_queue.db');
    return openDatabase(dbPath, version: 1, onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE pending_requests (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          method TEXT NOT NULL,
          path TEXT NOT NULL,
          body TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
    });
  }

  Future<void> enqueue(String method, String path, {String? body}) async {
    final db = await _database;
    await db.insert('pending_requests', {
      'method': method,
      'path': path,
      'body': body,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, Object?>>> dequeueAll() async {
    final db = await _database;
    return db.query('pending_requests', orderBy: 'created_at ASC');
  }

  Future<void> delete(int id) async {
    final db = await _database;
    await db.delete('pending_requests', where: 'id = ?', whereArgs: [id]);
  }
}
