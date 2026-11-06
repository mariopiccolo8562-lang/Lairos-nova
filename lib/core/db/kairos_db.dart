import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../download/download_manager.dart';
import '../models/models.dart';

/// Database SQLite con FTS5.
///
/// Perché SQLite e non liste in memoria: 299.000 canali come oggetti Dart
/// occupano centinaia di MB e bloccano la UI al primo filtro. Qui la UI
/// chiede solo le ~40 righe visibili (LIMIT/OFFSET su indice) e la ricerca
/// full-text risponde in pochi ms anche su 1M di righe.
class KairosDb {
  KairosDb._(this._db);

  final Database _db;
  static KairosDb? _instance;

  static Future<KairosDb> open() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'kairos_nova.db'));
    final db = sqlite3.open(file.path);
    final kdb = KairosDb._(db);
    kdb._configure();
    kdb._migrate();
    return _instance = kdb;
  }

  /// Apre il DB in un isolate separato (stesso file, WAL = letture concorrenti).
  static KairosDb openAtPath(String path) {
    final db = sqlite3.open(path);
    final kdb = KairosDb._(db);
    kdb._configure();
    kdb._migrate();
    return kdb;
  }

  String get path => _db.select('PRAGMA database_list').first['file'] as String;

  void _configure() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA temp_store = MEMORY');
    _db.execute('PRAGMA cache_size = -32768'); // 32 MB
    _db.execute('PRAGMA mmap_size = 268435456'); // 256 MB
    _db.execute('PRAGMA foreign_keys = ON');
    // Scritture concorrenti (import in isolate + UI): attesa fino a 5 s invece di SQLITE_BUSY immediato.
    _db.execute('PRAGMA busy_timeout = 5000');
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind INTEGER NOT NULL,
        source TEXT NOT NULL,
        epg_url TEXT,
        username TEXT,
        password TEXT,
        channel_count INTEGER NOT NULL DEFAULT 0,
        last_sync INTEGER,
        auto_refresh_hours INTEGER NOT NULL DEFAULT 12
      );

      CREATE TABLE IF NOT EXISTS channels (
        id INTEGER PRIMARY KEY,
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        url TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        logo TEXT,
        tvg_id TEXT,
        number INTEGER,
        type INTEGER NOT NULL DEFAULT 0,
        catchup_days INTEGER NOT NULL DEFAULT 0,
        headers TEXT,
        sort_key INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_ch_pl_group ON channels(playlist_id, type, group_name, sort_key);
      CREATE INDEX IF NOT EXISTS idx_ch_tvg ON channels(tvg_id);
      CREATE INDEX IF NOT EXISTS idx_ch_number ON channels(playlist_id, number);
      CREATE INDEX IF NOT EXISTS ch_type_name ON channels(type, name COLLATE NOCASE);

      CREATE VIRTUAL TABLE IF NOT EXISTS channels_fts USING fts5(
        name, group_name, content='channels', content_rowid='id',
        tokenize = 'unicode61 remove_diacritics 2'
      );
      CREATE TRIGGER IF NOT EXISTS ch_ai AFTER INSERT ON channels BEGIN
        INSERT INTO channels_fts(rowid, name, group_name) VALUES (new.id, new.name, new.group_name);
      END;
      CREATE TRIGGER IF NOT EXISTS ch_ad AFTER DELETE ON channels BEGIN
        INSERT INTO channels_fts(channels_fts, rowid, name, group_name) VALUES('delete', old.id, old.name, old.group_name);
      END;

      CREATE TABLE IF NOT EXISTS favorites (
        channel_key TEXT PRIMARY KEY,
        added_at INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS history (
        channel_id INTEGER PRIMARY KEY,
        played_at INTEGER NOT NULL,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_hist_time ON history(played_at DESC);

      CREATE TABLE IF NOT EXISTS epg_programs (
        id INTEGER PRIMARY KEY,
        tvg_id TEXT NOT NULL,
        title TEXT NOT NULL,
        start INTEGER NOT NULL,
        stop INTEGER NOT NULL,
        description TEXT,
        category TEXT,
        icon TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_epg_lookup ON epg_programs(tvg_id, start, stop);
      CREATE INDEX IF NOT EXISTS idx_epg_stop ON epg_programs(stop);

      CREATE TABLE IF NOT EXISTS stream_stats (
        url_hash TEXT PRIMARY KEY,
        ok_count INTEGER NOT NULL DEFAULT 0,
        fail_count INTEGER NOT NULL DEFAULT 0,
        avg_start_ms INTEGER NOT NULL DEFAULT 0,
        last_seen INTEGER
      );

      CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);

      CREATE TABLE IF NOT EXISTS downloads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        url TEXT NOT NULL,
        path TEXT NOT NULL,
        logo TEXT,
        headers TEXT,
        total INTEGER NOT NULL DEFAULT 0,
        received INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_dl_channel ON downloads(channel_id);
    ''');
    // Colonne aggiunte dopo la prima versione (ALTER fallisce se la colonna c'è già).
    try {
      _db.execute('ALTER TABLE stream_stats ADD COLUMN kbps INTEGER NOT NULL DEFAULT 0');
    } catch (_) {}
  }

  // ---------------------------------------------------------------- Playlist

  int insertPlaylist({
    required String name,
    required PlaylistKind kind,
    required String source,
    String? epgUrl,
    String? username,
    String? password,
  }) {
    _db.execute(
      'INSERT INTO playlists(name, kind, source, epg_url, username, password) VALUES (?,?,?,?,?,?)',
      [name, kind.index, source, epgUrl, username, password],
    );
    return _db.lastInsertRowId;
  }

  List<Playlist> playlists() =>
      _db.select('SELECT * FROM playlists ORDER BY id').map(_rowToPlaylist).toList();

  Playlist? playlist(int id) {
    final r = _db.select('SELECT * FROM playlists WHERE id = ?', [id]);
    return r.isEmpty ? null : _rowToPlaylist(r.first);
  }

  void deletePlaylist(int id) {
    _db.execute('DELETE FROM playlists WHERE id = ?', [id]);
    _db.execute("INSERT INTO channels_fts(channels_fts) VALUES('optimize')");
  }

  void markSynced(int id, int count) => _db.execute(
        'UPDATE playlists SET channel_count = ?, last_sync = ? WHERE id = ?',
        [count, DateTime.now().millisecondsSinceEpoch, id],
      );

  Playlist _rowToPlaylist(Row r) => Playlist(
        id: r['id'] as int,
        name: r['name'] as String,
        kind: PlaylistKind.values[r['kind'] as int],
        source: r['source'] as String,
        epgUrl: r['epg_url'] as String?,
        username: r['username'] as String?,
        password: r['password'] as String?,
        channelCount: r['channel_count'] as int,
        lastSync: r['last_sync'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_sync'] as int),
        autoRefreshHours: r['auto_refresh_hours'] as int,
      );

  // ---------------------------------------------------------------- Canali

  /// Inserimento bulk: una transazione, statement preparato, nessun trigger
  /// FTS per riga (ricostruito alla fine con 'rebuild' = 5-10x più veloce).
  /// Con [clear] i canali precedenti della lista si cancellano DENTRO la transazione:
  /// se l'import fallisce, il rollback li riporta (niente lista vuota).
  BulkInserter beginBulkInsert(int playlistId, {bool clear = false}) =>
      BulkInserter._(this, playlistId, clear: clear);

  void clearChannels(int playlistId) =>
      _db.execute('DELETE FROM channels WHERE playlist_id = ?', [playlistId]);

  int channelCount({int? playlistId, ChannelType? type, String? group}) {
    final (where, args) = _where(playlistId: playlistId, type: type, group: group);
    return _db.select('SELECT COUNT(*) c FROM channels $where', args).first['c'] as int;
  }

  /// Pagina di canali per liste virtualizzate (ListView.builder + cache LRU).
  List<Channel> channelsPage({
    int? playlistId,
    ChannelType? type,
    String? group,
    required int offset,
    required int limit,
  }) {
    final (where, args) = _where(playlistId: playlistId, type: type, group: group);
    final rows = _db.select(
      'SELECT * FROM channels $where ORDER BY sort_key LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    final favs = _favoriteKeys();
    return rows.map((r) => _rowToChannel(r, favs)).toList();
  }

  Channel? channel(int id) {
    final r = _db.select('SELECT * FROM channels WHERE id = ?', [id]);
    return r.isEmpty ? null : _rowToChannel(r.first, _favoriteKeys());
  }

  Channel? channelByNumber(int playlistId, int number) {
    final r = _db.select(
        'SELECT * FROM channels WHERE playlist_id = ? AND number = ? LIMIT 1',
        [playlistId, number]);
    return r.isEmpty ? null : _rowToChannel(r.first, _favoriteKeys());
  }

  /// Canale precedente/successivo nello stesso gruppo (zapping).
  Channel? neighbour(Channel c, {required bool next}) {
    final op = next ? '>' : '<';
    final ord = next ? 'ASC' : 'DESC';
    final r = _db.select(
      'SELECT * FROM channels WHERE playlist_id = ? AND type = ? AND group_name = ? '
      'AND sort_key $op (SELECT sort_key FROM channels WHERE id = ?) ORDER BY sort_key $ord LIMIT 1',
      [c.playlistId, c.type.index, c.groupName, c.id],
    );
    return r.isEmpty ? null : _rowToChannel(r.first, _favoriteKeys());
  }

  /// Link alternativi per lo stesso canale (stesso nome o stesso tvg-id):
  /// usati dal motore per il failover automatico. Due rami indicizzati
  /// (ch_type_name con COLLATE NOCASE, idx_ch_tvg): niente scansione completa.
  List<Channel> alternatives(Channel c, {int limit = 5}) {
    final tvg = (c.tvgId ?? '').trim();
    final r = _db.select(
      'SELECT * FROM channels WHERE id != ? AND type = ? AND name = ? COLLATE NOCASE '
      '${tvg.isEmpty ? '' : 'UNION SELECT * FROM channels WHERE id != ? AND type = ? AND tvg_id = ? '}'
      'LIMIT ?',
      [c.id, c.type.index, c.name, if (tvg.isNotEmpty) ...[c.id, c.type.index, tvg], limit],
    );
    return r.map((e) => _rowToChannel(e, const {})).toList();
  }

  List<ChannelGroup> groups({int? playlistId, ChannelType? type}) {
    final (where, args) = _where(playlistId: playlistId, type: type);
    final rows = _db.select(
      'SELECT group_name, type, COUNT(*) c FROM channels $where GROUP BY group_name, type ORDER BY MIN(sort_key)',
      args,
    );
    return rows
        .map((r) => ChannelGroup(
              name: r['group_name'] as String,
              count: r['c'] as int,
              type: ChannelType.values[r['type'] as int],
            ))
        .toList();
  }

  /// Ricerca full-text con prefix matching: "sky sp" trova "Sky Sport F1 HD".
  List<Channel> search(String query, {ChannelType? type, int limit = 200}) {
    final q = _ftsQuery(query);
    if (q.isEmpty) return const [];
    final typeClause = type == null ? '' : 'AND c.type = ${type.index}';
    final rows = _db.select(
      'SELECT c.* FROM channels_fts f JOIN channels c ON c.id = f.rowid '
      'WHERE channels_fts MATCH ? $typeClause ORDER BY bm25(channels_fts), c.sort_key LIMIT ?',
      [q, limit],
    );
    final favs = _favoriteKeys();
    return rows.map((r) => _rowToChannel(r, favs)).toList();
  }

  static String _ftsQuery(String raw) {
    final terms = raw
        .trim()
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll(RegExp(r'["*^()\-:]'), ''))
        .where((t) => t.isNotEmpty)
        .map((t) => '"$t"*');
    return terms.join(' ');
  }

  (String, List<Object?>) _where(
      {int? playlistId, ChannelType? type, String? group}) {
    final parts = <String>[];
    final args = <Object?>[];
    if (playlistId != null) {
      parts.add('playlist_id = ?');
      args.add(playlistId);
    }
    if (type != null) {
      parts.add('type = ?');
      args.add(type.index);
    }
    if (group != null) {
      parts.add('group_name = ?');
      args.add(group);
    }
    return (parts.isEmpty ? '' : 'WHERE ${parts.join(' AND ')}', args);
  }

  Channel _rowToChannel(Row r, Set<String> favs) {
    final name = r['name'] as String;
    final url = r['url'] as String;
    return Channel(
      id: r['id'] as int,
      playlistId: r['playlist_id'] as int,
      name: name,
      url: url,
      groupName: r['group_name'] as String,
      logo: r['logo'] as String?,
      tvgId: r['tvg_id'] as String?,
      number: r['number'] as int?,
      type: ChannelType.values[r['type'] as int],
      isFavorite: favs.contains(favKey(name, url)),
      catchupDays: r['catchup_days'] as int,
      headers: _decodeHeaders(r['headers'] as String?),
    );
  }

  static Map<String, String>? _decodeHeaders(String? s) {
    if (s == null || s.isEmpty) return null;
    final map = <String, String>{};
    for (final line in s.split('\n')) {
      final i = line.indexOf('=');
      if (i > 0) map[line.substring(0, i)] = line.substring(i + 1);
    }
    return map;
  }

  static String encodeHeaders(Map<String, String> h) =>
      h.entries.map((e) => '${e.key}=${e.value}').join('\n');

  // ---------------------------------------------------------------- Preferiti
  // Chiave = nome+url: i preferiti sopravvivono al refresh della lista
  // (gli id dei canali vengono ricreati a ogni import).

  static String favKey(String name, String url) => '${name.toLowerCase()}|$url';

  Set<String>? _favCache;
  Set<String> _favoriteKeys() => _favCache ??= _db
      .select('SELECT channel_key FROM favorites')
      .map((r) => r['channel_key'] as String)
      .toSet();

  bool toggleFavorite(Channel c) {
    final key = favKey(c.name, c.url);
    final exists = _favoriteKeys().contains(key);
    if (exists) {
      _db.execute('DELETE FROM favorites WHERE channel_key = ?', [key]);
    } else {
      _db.execute('INSERT OR IGNORE INTO favorites VALUES (?, ?)',
          [key, DateTime.now().millisecondsSinceEpoch]);
    }
    _favCache = null;
    return !exists;
  }

  List<Channel> favorites({int limit = 500}) {
    final rows = _db.select(
      'SELECT c.* FROM channels c JOIN favorites f ON f.channel_key = lower(c.name) || \'|\' || c.url '
      'ORDER BY f.added_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => _rowToChannel(r, _favoriteKeys())).toList();
  }

  // ---------------------------------------------------------------- Cronologia

  void recordPlay(Channel c, {int positionMs = 0, int durationMs = 0}) {
    _db.execute(
      'INSERT INTO history(channel_id, played_at, position_ms, duration_ms) VALUES (?,?,?,?) '
      'ON CONFLICT(channel_id) DO UPDATE SET played_at = excluded.played_at, '
      'position_ms = excluded.position_ms, duration_ms = excluded.duration_ms',
      [c.id, DateTime.now().millisecondsSinceEpoch, positionMs, durationMs],
    );
    _db.execute(
        'DELETE FROM history WHERE channel_id NOT IN (SELECT channel_id FROM history ORDER BY played_at DESC LIMIT 200)');
  }

  List<Channel> recent({int limit = 30}) {
    final rows = _db.select(
      'SELECT c.* FROM history h JOIN channels c ON c.id = h.channel_id ORDER BY h.played_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => _rowToChannel(r, _favoriteKeys())).toList();
  }

  int resumePosition(int channelId) {
    final r = _db.select(
        'SELECT position_ms FROM history WHERE channel_id = ?', [channelId]);
    return r.isEmpty ? 0 : r.first['position_ms'] as int;
  }

  // ---------------------------------------------------------------- EPG

  EpgBulkInserter beginEpgInsert() => EpgBulkInserter._(this);

  void purgeOldEpg() => _db.execute('DELETE FROM epg_programs WHERE stop < ?',
      [DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch]);

  NowNext nowNext(String? tvgId, [DateTime? at]) {
    if (tvgId == null || tvgId.isEmpty) return const NowNext();
    final now = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = _db.select(
      'SELECT * FROM epg_programs WHERE tvg_id = ? AND stop > ? ORDER BY start LIMIT 2',
      [tvgId, now],
    );
    if (rows.isEmpty) return const NowNext();
    final first = _rowToProgram(rows.first);
    if (first.start.millisecondsSinceEpoch > now) {
      return NowNext(next: first);
    }
    return NowNext(
        now: first, next: rows.length > 1 ? _rowToProgram(rows[1]) : null);
  }

  /// Programmi di molti canali in una finestra temporale (griglia EPG).
  Map<String, List<EpgProgram>> programsFor(
      Iterable<String> tvgIds, DateTime from, DateTime to) {
    final ids = tvgIds.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};
    final out = <String, List<EpgProgram>>{};
    // Chunk per restare sotto il limite di variabili SQLite.
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, (i + 400).clamp(0, ids.length));
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = _db.select(
        'SELECT * FROM epg_programs WHERE tvg_id IN ($marks) AND stop > ? AND start < ? ORDER BY tvg_id, start',
        [...chunk, from.millisecondsSinceEpoch, to.millisecondsSinceEpoch],
      );
      for (final r in rows) {
        final p = _rowToProgram(r);
        (out[p.tvgId] ??= []).add(p);
      }
    }
    return out;
  }

  List<EpgProgram> searchPrograms(String q, {int limit = 100}) {
    final rows = _db.select(
      'SELECT * FROM epg_programs WHERE title LIKE ? AND stop > ? ORDER BY start LIMIT ?',
      ['%$q%', DateTime.now().millisecondsSinceEpoch, limit],
    );
    return rows.map(_rowToProgram).toList();
  }

  EpgProgram _rowToProgram(Row r) => EpgProgram(
        tvgId: r['tvg_id'] as String,
        title: r['title'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(r['start'] as int),
        stop: DateTime.fromMillisecondsSinceEpoch(r['stop'] as int),
        description: r['description'] as String?,
        category: r['category'] as String?,
        icon: r['icon'] as String?,
      );

  // ---------------------------------------------------------------- Stats stream

  void recordStreamResult(String url, {required bool ok, int startMs = 0}) {
    final h = url.hashCode.toRadixString(16);
    _db.execute(
      'INSERT INTO stream_stats(url_hash, ok_count, fail_count, avg_start_ms, last_seen) VALUES (?,?,?,?,?) '
      'ON CONFLICT(url_hash) DO UPDATE SET ok_count = ok_count + excluded.ok_count, '
      'fail_count = fail_count + excluded.fail_count, '
      'avg_start_ms = (avg_start_ms + excluded.avg_start_ms) / 2, last_seen = excluded.last_seen',
      [h, ok ? 1 : 0, ok ? 0 : 1, startMs, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Bitrate medio osservato su un link (kbit/s): serve a scegliere la «versione più leggera» sui TS.
  void recordStreamBitrate(String url, int kbps) {
    if (kbps <= 0) return;
    _db.execute(
      'INSERT INTO stream_stats(url_hash, kbps, last_seen) VALUES (?,?,?) '
      'ON CONFLICT(url_hash) DO UPDATE SET kbps = CASE WHEN kbps = 0 THEN excluded.kbps ELSE (kbps + excluded.kbps) / 2 END, '
      'last_seen = excluded.last_seen',
      [url.hashCode.toRadixString(16), kbps, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Bitrate noto di un link (kbit/s), 0 se mai visto.
  int knownKbps(String url) {
    final r = _db.select('SELECT kbps FROM stream_stats WHERE url_hash = ?', [url.hashCode.toRadixString(16)]);
    return r.isEmpty ? 0 : (r.first['kbps'] as int? ?? 0);
  }

  /// Punteggio affidabilità 0..1 (usato per ordinare i link alternativi).
  double reliability(String url) {
    final r = _db.select(
        'SELECT ok_count, fail_count FROM stream_stats WHERE url_hash = ?',
        [url.hashCode.toRadixString(16)]);
    if (r.isEmpty) return 0.5;
    final ok = r.first['ok_count'] as int;
    final fail = r.first['fail_count'] as int;
    return (ok + 1) / (ok + fail + 2);
  }

  // ---------------------------------------------------------------- Download

  int insertDownload({
    required int channelId,
    required String name,
    required String url,
    required String path,
    String? logo,
    String? headers,
  }) {
    _db.execute(
      'INSERT INTO downloads(channel_id, name, url, path, logo, headers, created_at) VALUES (?,?,?,?,?,?,?)',
      [channelId, name, url, path, logo, headers, DateTime.now().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  List<DownloadItem> downloads() =>
      _db.select('SELECT * FROM downloads ORDER BY created_at DESC').map(_rowToDownload).toList();

  DownloadItem? download(int id) {
    final r = _db.select('SELECT * FROM downloads WHERE id = ?', [id]);
    return r.isEmpty ? null : _rowToDownload(r.first);
  }

  DownloadItem? downloadForChannel(int channelId) {
    final r = _db.select('SELECT * FROM downloads WHERE channel_id = ? LIMIT 1', [channelId]);
    return r.isEmpty ? null : _rowToDownload(r.first);
  }

  Map<String, String>? downloadHeaders(int id) {
    final r = _db.select('SELECT headers FROM downloads WHERE id = ?', [id]);
    return r.isEmpty ? null : _decodeHeaders(r.first['headers'] as String?);
  }

  void setDownloadStatus(int id, DownloadStatus s, {String? error}) => _db.execute(
      'UPDATE downloads SET status = ?, error = ? WHERE id = ?', [s.index, error, id]);

  void updateDownloadProgress(int id, {required int received, required int total}) => _db.execute(
      'UPDATE downloads SET received = ?, total = ? WHERE id = ?', [received, total, id]);

  void resetRunningDownloads() => _db.execute(
      'UPDATE downloads SET status = ? WHERE status = ?',
      [DownloadStatus.queued.index, DownloadStatus.running.index]);

  void deleteDownload(int id) => _db.execute('DELETE FROM downloads WHERE id = ?', [id]);

  DownloadItem _rowToDownload(Row r) => DownloadItem(
        id: r['id'] as int,
        channelId: r['channel_id'] as int,
        name: r['name'] as String,
        url: r['url'] as String,
        path: r['path'] as String,
        logo: r['logo'] as String?,
        total: r['total'] as int,
        received: r['received'] as int,
        status: DownloadStatus.values[r['status'] as int],
        error: r['error'] as String?,
      );

  // ---------------------------------------------------------------- KV

  String? get(String key) {
    final r = _db.select('SELECT value FROM kv WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  void set(String key, String value) => _db.execute(
      'INSERT INTO kv VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value]);

  void close() => _db.dispose();
}

/// Inserimento massivo canali: ~150k righe/s su un telefono medio.
class BulkInserter {
  BulkInserter._(this._kdb, this.playlistId, {bool clear = false}) {
    _db = _kdb._db;
    _db.execute('BEGIN');
    _db.execute('DROP TRIGGER IF EXISTS ch_ai');
    if (clear) {
      // vecchi canali via nella stessa transazione (senza trigger FTS per riga: l'indice si ricostruisce al commit)
      _db.execute('DROP TRIGGER IF EXISTS ch_ad');
      _db.execute('DELETE FROM channels WHERE playlist_id = ?', [playlistId]);
    }
    _stmt = _db.prepare(
      'INSERT INTO channels(playlist_id, name, url, group_name, logo, tvg_id, number, type, catchup_days, headers, sort_key) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    );
  }

  final KairosDb _kdb;
  final int playlistId;
  late final Database _db;
  late final PreparedStatement _stmt;
  int _sort = 0;
  int count = 0;

  void add({
    required String name,
    required String url,
    String group = '',
    String? logo,
    String? tvgId,
    int? number,
    ChannelType type = ChannelType.live,
    int catchupDays = 0,
    Map<String, String>? headers,
  }) {
    _stmt.execute([
      playlistId,
      name,
      url,
      group,
      logo,
      tvgId,
      number,
      type.index,
      catchupDays,
      headers == null ? null : KairosDb.encodeHeaders(headers),
      _sort++,
    ]);
    count++;
  }

  void commit() {
    _stmt.dispose();
    _db.execute('COMMIT');
    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS ch_ai AFTER INSERT ON channels BEGIN
        INSERT INTO channels_fts(rowid, name, group_name) VALUES (new.id, new.name, new.group_name);
      END;
      CREATE TRIGGER IF NOT EXISTS ch_ad AFTER DELETE ON channels BEGIN
        INSERT INTO channels_fts(channels_fts, rowid, name, group_name) VALUES('delete', old.id, old.name, old.group_name);
      END;
    ''');
    _db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild')");
    _db.execute("INSERT INTO channels_fts(channels_fts) VALUES('optimize')");
    _kdb.markSynced(playlistId, count);
    _kdb._favCache = null;
  }

  void rollback() {
    _stmt.dispose();
    _db.execute('ROLLBACK');
  }
}

class EpgBulkInserter {
  EpgBulkInserter._(this._kdb) {
    _db = _kdb._db;
    _db.execute('BEGIN');
    _db.execute('DELETE FROM epg_programs');
    _stmt = _db.prepare(
        'INSERT INTO epg_programs(tvg_id, title, start, stop, description, category, icon) VALUES (?,?,?,?,?,?,?)');
  }

  final KairosDb _kdb;
  late final Database _db;
  late final PreparedStatement _stmt;
  int count = 0;

  void add(EpgProgram p) {
    _stmt.execute([
      p.tvgId,
      p.title,
      p.start.millisecondsSinceEpoch,
      p.stop.millisecondsSinceEpoch,
      p.description,
      p.category,
      p.icon,
    ]);
    count++;
  }

  void commit() {
    _stmt.dispose();
    _db.execute('COMMIT');
    _kdb.set('epg_updated', DateTime.now().millisecondsSinceEpoch.toString());
  }

  void rollback() {
    _stmt.dispose();
    _db.execute('ROLLBACK');
  }
}
