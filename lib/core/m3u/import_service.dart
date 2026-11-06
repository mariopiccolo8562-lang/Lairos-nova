import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../db/kairos_db.dart';
import '../epg/xmltv_parser.dart';
import '../models/models.dart';
import 'm3u_parser.dart';

/// Importa playlist ed EPG in un isolate dedicato.
///
/// La UI riceve uno stream di [ImportProgress] e resta a 60/120 fps anche
/// mentre vengono scritti 299k canali: il thread principale non tocca mai
/// né la rete né il database durante l'import.
class ImportService {
  ImportService(this.dbPath);
  final String dbPath;

  Stream<ImportProgress> importPlaylist(Playlist playlist) {
    final controller = StreamController<ImportProgress>();
    final receive = ReceivePort();

    receive.listen((msg) {
      if (msg is ImportProgress) {
        controller.add(msg);
        if (msg.done || msg.error != null) {
          receive.close();
          controller.close();
        }
      } else if (msg is List && msg.isNotEmpty) {
        controller.add(ImportProgress(phase: 'Errore', error: '${msg.first}'));
        receive.close();
        controller.close();
      }
    });

    Isolate.spawn(
      _playlistWorker,
      _Job(
        sendPort: receive.sendPort,
        dbPath: dbPath,
        playlistId: playlist.id,
        kind: playlist.kind,
        source: playlist.source,
        username: playlist.username,
        password: playlist.password,
      ),
      errorsAreFatal: true,
      onError: receive.sendPort,
    ).catchError((e) {
      controller.add(ImportProgress(phase: 'Errore', error: '$e'));
      controller.close();
      receive.close();
      return Future<Isolate>.error(e);
    });

    return controller.stream;
  }

  Stream<ImportProgress> importEpg(String url) {
    final controller = StreamController<ImportProgress>();
    final receive = ReceivePort();
    receive.listen((msg) {
      if (msg is ImportProgress) {
        controller.add(msg);
        if (msg.done || msg.error != null) {
          receive.close();
          controller.close();
        }
      }
    });
    Isolate.spawn(
      _epgWorker,
      _Job(sendPort: receive.sendPort, dbPath: dbPath, playlistId: 0,
          kind: PlaylistKind.m3uUrl, source: url),
    );
    return controller.stream;
  }
}

class _Job {
  _Job({
    required this.sendPort,
    required this.dbPath,
    required this.playlistId,
    required this.kind,
    required this.source,
    this.username,
    this.password,
  });
  final SendPort sendPort;
  final String dbPath;
  final int playlistId;
  final PlaylistKind kind;
  final String source;
  final String? username;
  final String? password;
}

// --------------------------------------------------------------- Worker M3U

Future<void> _playlistWorker(_Job job) async {
  final send = job.sendPort;
  KairosDb? db;
  BulkInserter? bulk;
  try {
    db = KairosDb.openAtPath(job.dbPath);
    send.send(const ImportProgress(phase: 'Connessione…'));

    final Stream<List<int>> bytes;
    int? total;

    if (job.kind == PlaylistKind.m3uFile) {
      final f = File(job.source);
      total = await f.length();
      bytes = f.openRead();
    } else {
      final uri = Uri.parse(job.kind == PlaylistKind.xtream
          ? '${job.source}/get.php?username=${job.username}&password=${job.password}&type=m3u_plus&output=ts'
          : job.source);
      final client = http.Client();
      final req = http.Request('GET', uri)
        ..headers['User-Agent'] = 'KairosNova/1.0'
        ..headers['Accept-Encoding'] = 'gzip';
      final res = await client.send(req).timeout(const Duration(seconds: 40));
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode} dal server della lista');
      }
      total = res.contentLength;
      bytes = res.stream;
    }

    send.send(const ImportProgress(phase: 'Download e analisi…'));
    db.clearChannels(job.playlistId);
    bulk = db.beginBulkInsert(job.playlistId);

    final parser = M3uStreamParser();
    var read = 0;
    var lastReport = DateTime.now();

    void addEntry(M3uEntry e) {
      bulk!.add(
        name: e.name,
        url: e.url,
        group: e.group,
        logo: e.logo,
        tvgId: e.tvgId,
        number: e.number,
        type: e.type,
        catchupDays: e.catchupDays,
        headers: e.headers,
      );
    }

    await for (final chunk in bytes) {
      read += chunk.length;
      for (final e in parser.feed(chunk)) {
        addEntry(e);
      }
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds > 120) {
        lastReport = now;
        send.send(ImportProgress(
          phase: 'Analisi canali…',
          parsed: bulk.count,
          bytesRead: read,
          totalBytes: total,
        ));
      }
    }
    for (final e in parser.flush()) {
      addEntry(e);
    }

    send.send(ImportProgress(
        phase: 'Indicizzazione ricerca…', parsed: bulk.count, bytesRead: read, totalBytes: total));
    bulk.commit();

    send.send(ImportProgress(
        phase: 'Completato', parsed: bulk.count, bytesRead: read, totalBytes: total, done: true));
  } catch (e) {
    bulk?.rollback();
    send.send(ImportProgress(phase: 'Errore', error: _friendly(e)));
  } finally {
    db?.close();
  }
}

// --------------------------------------------------------------- Worker EPG

Future<void> _epgWorker(_Job job) async {
  final send = job.sendPort;
  KairosDb? db;
  EpgBulkInserter? bulk;
  try {
    db = KairosDb.openAtPath(job.dbPath);
    send.send(const ImportProgress(phase: 'Scarico guida TV…'));

    final client = http.Client();
    final req = http.Request('GET', Uri.parse(job.source))
      ..headers['User-Agent'] = 'KairosNova/1.0';
    final res = await client.send(req).timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode} dal server EPG');

    Stream<List<int>> stream = res.stream;
    final isGz = job.source.endsWith('.gz') ||
        (res.headers['content-type'] ?? '').contains('gzip');
    if (isGz) stream = stream.transform(gzip.decoder);

    bulk = db.beginEpgInsert();
    final parser = XmltvStreamParser();
    final horizonEnd = DateTime.now().add(const Duration(days: 7));
    final horizonStart = DateTime.now().subtract(const Duration(hours: 12));
    var read = 0;
    var lastReport = DateTime.now();

    await for (final chunk in stream) {
      read += chunk.length;
      for (final p in parser.feed(chunk)) {
        if (p.stop.isAfter(horizonStart) && p.start.isBefore(horizonEnd)) {
          bulk.add(p);
        }
      }
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds > 150) {
        lastReport = now;
        send.send(ImportProgress(
            phase: 'Analisi programmi…', parsed: bulk.count, bytesRead: read, totalBytes: res.contentLength));
      }
    }
    for (final p in parser.flush()) {
      bulk.add(p);
    }
    bulk.commit();
    send.send(ImportProgress(phase: 'Guida TV aggiornata', parsed: bulk.count, done: true));
  } catch (e) {
    bulk?.rollback();
    send.send(ImportProgress(phase: 'Errore', error: _friendly(e)));
  } finally {
    db?.close();
  }
}

String _friendly(Object e) {
  final s = e.toString();
  if (e is SocketException) return 'Nessuna connessione o server irraggiungibile';
  if (e is TimeoutException) return 'Il server non risponde (timeout)';
  if (s.contains('HandshakeException')) return 'Certificato SSL non valido';
  return s.replaceFirst('Exception: ', '');
}
