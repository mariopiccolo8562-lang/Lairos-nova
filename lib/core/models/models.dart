/// Modelli immutabili e leggeri. Nessuna reflection, nessun codegen:
/// vengono costruiti direttamente dalle righe SQLite.

enum PlaylistKind { m3uUrl, m3uFile, xtream }

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.kind,
    required this.source,
    this.epgUrl,
    this.username,
    this.password,
    this.channelCount = 0,
    this.lastSync,
    this.autoRefreshHours = 12,
  });

  final int id;
  final String name;
  final PlaylistKind kind;

  /// URL M3U, percorso file o base URL Xtream.
  final String source;
  final String? epgUrl;
  final String? username;
  final String? password;
  final int channelCount;
  final DateTime? lastSync;
  final int autoRefreshHours;

  Playlist copyWith({int? channelCount, DateTime? lastSync, String? name}) =>
      Playlist(
        id: id,
        name: name ?? this.name,
        kind: kind,
        source: source,
        epgUrl: epgUrl,
        username: username,
        password: password,
        channelCount: channelCount ?? this.channelCount,
        lastSync: lastSync ?? this.lastSync,
        autoRefreshHours: autoRefreshHours,
      );
}

enum ChannelType { live, movie, series, radio }

class Channel {
  const Channel({
    required this.id,
    required this.playlistId,
    required this.name,
    required this.url,
    this.groupName = '',
    this.logo,
    this.tvgId,
    this.number,
    this.type = ChannelType.live,
    this.isFavorite = false,
    this.catchupDays = 0,
    this.headers,
  });

  final int id;
  final int playlistId;
  final String name;
  final String url;
  final String groupName;
  final String? logo;
  final String? tvgId;
  final int? number;
  final ChannelType type;
  final bool isFavorite;
  final int catchupDays;

  /// Header HTTP extra (es. User-Agent, Referer) da #EXTVLCOPT.
  final Map<String, String>? headers;

  Channel copyWith({bool? isFavorite}) => Channel(
        id: id,
        playlistId: playlistId,
        name: name,
        url: url,
        groupName: groupName,
        logo: logo,
        tvgId: tvgId,
        number: number,
        type: type,
        isFavorite: isFavorite ?? this.isFavorite,
        catchupDays: catchupDays,
        headers: headers,
      );
}

class ChannelGroup {
  const ChannelGroup({required this.name, required this.count, this.type});
  final String name;
  final int count;
  final ChannelType? type;
}

class EpgProgram {
  const EpgProgram({
    required this.tvgId,
    required this.title,
    required this.start,
    required this.stop,
    this.description,
    this.category,
    this.icon,
  });

  final String tvgId;
  final String title;
  final DateTime start;
  final DateTime stop;
  final String? description;
  final String? category;
  final String? icon;

  Duration get duration => stop.difference(start);

  double progressAt(DateTime now) {
    if (now.isBefore(start)) return 0;
    if (now.isAfter(stop)) return 1;
    final total = duration.inSeconds;
    if (total <= 0) return 1;
    return now.difference(start).inSeconds / total;
  }
}

class NowNext {
  const NowNext({this.now, this.next});
  final EpgProgram? now;
  final EpgProgram? next;
}

/// Stato di salute dello stream mostrato nell'overlay "Diagnostica".
class StreamHealth {
  const StreamHealth({
    this.bufferSeconds = 0,
    this.bitrateKbps = 0,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.droppedFrames = 0,
    this.reconnects = 0,
    this.latencyMs = 0,
    this.codec = '',
  });

  final double bufferSeconds;
  final int bitrateKbps;
  final int width;
  final int height;
  final double fps;
  final int droppedFrames;
  final int reconnects;
  final int latencyMs;
  final String codec;

  String get resolutionLabel {
    if (height >= 2100) return '4K';
    if (height >= 1000) return 'FHD';
    if (height >= 700) return 'HD';
    if (height > 0) return 'SD';
    return '—';
  }
}

class ImportProgress {
  const ImportProgress({
    required this.phase,
    this.parsed = 0,
    this.bytesRead = 0,
    this.totalBytes,
    this.done = false,
    this.error,
  });

  final String phase;
  final int parsed;
  final int bytesRead;
  final int? totalBytes;
  final bool done;
  final String? error;

  double? get fraction =>
      totalBytes == null || totalBytes == 0 ? null : bytesRead / totalBytes!;
}
