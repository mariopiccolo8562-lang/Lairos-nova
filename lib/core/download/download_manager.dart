import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/kairos_db.dart';
import '../models/models.dart';

enum DownloadStatus { queued, running, paused, done, failed }

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.channelId,
    required this.name,
    required this.url,
    required this.path,
    this.logo,
    this.total = 0,
    this.received = 0,
    this.status = DownloadStatus.queued,
    this.error,
    this.speedBps = 0,
  });

  final int id;
  final int channelId;
  final String name;
  final String url;
  final String path;
  final String? logo;
  final int total;
  final int received;
  final DownloadStatus status;
  final String? error;
  final int speedBps;

  double? get fraction => total <= 0 ? null : received / total;

  DownloadItem copyWith({
    int? total,
    int? received,
    DownloadStatus? status,
    String? error,
    int? speedBps,
  }) =>
      DownloadItem(
        id: id,
        channelId: channelId,
        name: name,
        url: url,
        path: path,
        logo: logo,
        total: total ?? this.total,
        received: received ?? this.received,
        status: status ?? this.status,
        error: error,
        speedBps: speedBps ?? this.speedBps,
      );
}

/// Download manager per contenuti VOD (film/serie) → visione offline.
///
/// - coda con N download paralleli (default 2)
/// - ripresa con `Range:` dopo pausa, crash o riavvio app
/// - header HTTP del canale rispettati (User-Agent, Referer)
/// - stato persistito in SQLite, file in Documents/KairosNova/
/// - velocità e progresso in tempo reale tramite [ValueNotifier]
class DownloadManager {
  DownloadManager(this._db, {this.maxParallel = 2});

  final KairosDb _db;
  final int maxParallel;

  final items = ValueNotifier<List<DownloadItem>>(const []);
  final _clients = <int, http.Client>{};
  final _cancelled = <int>{};
  Directory? _dir;

  Future<void> init() async {
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory(p.join(base.path, 'KairosNova'));
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    // I download rimasti "running" dopo un crash tornano in coda.
    _db.resetRunningDownloads();
    _refresh();
    _pump();
  }

  Future<Directory> get directory async {
    if (_dir == null) await init();
    return _dir!;
  }

  // ----------------------------------------------------------------- API

  Future<DownloadItem?> enqueue(Channel c) async {
    final dir = await directory;
    if (_db.downloadForChannel(c.id) != null) return null;
    final safe = c.name.replaceAll(RegExp(r'[^\w\s\-\.\(\)]'), '').trim();
    final ext = _extFromUrl(c.url);
    final path = p.join(dir.path, '${c.id}_$safe$ext');
    final id = _db.insertDownload(
      channelId: c.id, name: c.name, url: c.url, path: path, logo: c.logo,
      headers: c.headers == null ? null : KairosDb.encodeHeaders(c.headers!),
    );
    _refresh();
    _pump();
    return _db.download(id);
  }

  void pause(int id) {
    _cancelled.add(id);
    _clients.remove(id)?.close();
    _db.setDownloadStatus(id, DownloadStatus.paused);
    _refresh();
    _pump();
  }

  void resume(int id) {
    _db.setDownloadStatus(id, DownloadStatus.queued, error: null);
    _refresh();
    _pump();
  }

  void retry(int id) => resume(id);

  Future<void> delete(int id) async {
    _cancelled.add(id);
    _clients.remove(id)?.close();
    final item = _db.download(id);
    if (item != null) {
      final f = File(item.path);
      if (await f.exists()) await f.delete();
      final part = File('${item.path}.part');
      if (await part.exists()) await part.delete();
    }
    _db.deleteDownload(id);
    _refresh();
    _pump();
  }

  /// Percorso locale se il contenuto è stato scaricato per intero.
  String? localPathFor(int channelId) {
    final d = _db.downloadForChannel(channelId);
    if (d == null || d.status != DownloadStatus.done) return null;
    return File(d.path).existsSync() ? d.path : null;
  }

  Future<int> usedBytes() async {
    final dir = await directory;
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  void dispose() {
    for (final c in _clients.values) {
      c.close();
    }
    _clients.clear();
    items.dispose();
  }

  // ----------------------------------------------------------------- Interno

  void _refresh() => items.value = _db.downloads();

  void _pump() {
    final running = _db.downloads().where((d) => d.status == DownloadStatus.running).length;
    if (running >= maxParallel) return;
    final next = _db.downloads().where((d) => d.status == DownloadStatus.queued).toList();
    for (final d in next.take(maxParallel - running)) {
      _cancelled.remove(d.id);
      _db.setDownloadStatus(d.id, DownloadStatus.running);
      _refresh();
      unawaited(_run(d.id));
    }
  }

  Future<void> _run(int id) async {
    final item = _db.download(id);
    if (item == null) return;
    final part = File('${item.path}.part');
    final client = http.Client();
    _clients[id] = client;
    IOSink? sink;
    try {
      var have = await part.exists() ? await part.length() : 0;
      final req = http.Request('GET', Uri.parse(item.url));
      req.headers['User-Agent'] = 'KairosNova/1.0';
      final extra = _db.downloadHeaders(id);
      if (extra != null) req.headers.addAll(extra);
      if (have > 0) req.headers['Range'] = 'bytes=$have-';

      final res = await client.send(req).timeout(const Duration(seconds: 40));
      if (res.statusCode == 416) {
        // Range oltre la fine: file già completo
        await _finish(id, item, part);
        return;
      }
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}');
      final resumed = res.statusCode == 206;
      if (!resumed) have = 0;
      final total = resumed
          ? have + (res.contentLength ?? 0)
          : (res.contentLength ?? 0);
      _db.updateDownloadProgress(id, received: have, total: total);

      sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var received = have;
      var lastTick = DateTime.now();
      var lastBytes = received;
      var speed = 0;

      await for (final chunk in res.stream) {
        if (_cancelled.contains(id)) break;
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        final dt = now.difference(lastTick).inMilliseconds;
        if (dt >= 500) {
          speed = ((received - lastBytes) * 1000 / dt).round();
          lastTick = now;
          lastBytes = received;
          _db.updateDownloadProgress(id, received: received, total: total);
          _emitProgress(id, received, total, speed);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (_cancelled.contains(id)) {
        _db.updateDownloadProgress(id, received: received, total: total);
        _refresh();
        return;
      }
      if (total > 0 && received < total) {
        throw const HttpException('Connessione interrotta');
      }
      await _finish(id, item, part);
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      if (!_cancelled.contains(id)) {
        _db.setDownloadStatus(id, DownloadStatus.failed, error: _friendly(e));
        _refresh();
      }
    } finally {
      _clients.remove(id)?.close();
      _pump();
    }
  }

  Future<void> _finish(int id, DownloadItem item, File part) async {
    if (await part.exists()) await part.rename(item.path);
    final size = await File(item.path).length();
    _db.updateDownloadProgress(id, received: size, total: size);
    _db.setDownloadStatus(id, DownloadStatus.done);
    _refresh();
  }

  void _emitProgress(int id, int received, int total, int speed) {
    final list = items.value;
    final idx = list.indexWhere((d) => d.id == id);
    if (idx < 0) return;
    final copy = [...list];
    copy[idx] = list[idx].copyWith(received: received, total: total, speedBps: speed, status: DownloadStatus.running);
    items.value = copy;
  }

  static String _extFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final m = RegExp(r'\.(mp4|mkv|avi|mov|m4v|webm|ts|mp3|aac)$', caseSensitive: false).firstMatch(path);
    return m == null ? '.mp4' : '.${m.group(1)!.toLowerCase()}';
  }

  static String _friendly(Object e) {
    if (e is SocketException) return 'Rete non disponibile';
    if (e is TimeoutException) return 'Timeout del server';
    if (e is FileSystemException) return 'Spazio insufficiente o errore disco';
    return e.toString().replaceFirst('HttpException: ', '').replaceFirst('Exception: ', '');
  }
}

/// Formattazione dimensioni/velocità.
String fmtBytes(num b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}
