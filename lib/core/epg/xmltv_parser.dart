import 'dart:convert';

import '../models/models.dart';

/// Parser XMLTV incrementale, senza DOM: file EPG da 500 MB passano in
/// streaming con memoria costante. Estrae solo i campi utili.
class XmltvStreamParser {
  final _decoder = const Utf8Decoder(allowMalformed: true);
  String _buf = '';

  static final _progOpen = RegExp(
      r'<programme\s+([^>]*)>', caseSensitive: false);
  static final _attr = RegExp(r'(\w+)="([^"]*)"');
  static final _title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false);
  static final _desc = RegExp(r'<desc[^>]*>([\s\S]*?)</desc>', caseSensitive: false);
  static final _cat = RegExp(r'<category[^>]*>([\s\S]*?)</category>', caseSensitive: false);
  static final _icon = RegExp(r'<icon\s+src="([^"]*)"', caseSensitive: false);

  Iterable<EpgProgram> feed(List<int> bytes) sync* {
    _buf += _decoder.convert(bytes);
    while (true) {
      final start = _buf.indexOf('<programme');
      if (start < 0) {
        // Tieni solo la coda (potrebbe contenere l'inizio di "<programme")
        if (_buf.length > 64) _buf = _buf.substring(_buf.length - 64);
        return;
      }
      final end = _buf.indexOf('</programme>', start);
      if (end < 0) {
        if (start > 0) _buf = _buf.substring(start);
        return;
      }
      final block = _buf.substring(start, end + 12);
      _buf = _buf.substring(end + 12);
      final p = _parse(block);
      if (p != null) yield p;
    }
  }

  Iterable<EpgProgram> flush() sync* {
    _buf = '';
  }

  EpgProgram? _parse(String block) {
    final open = _progOpen.firstMatch(block);
    if (open == null) return null;
    String? start, stop, channel;
    for (final a in _attr.allMatches(open.group(1)!)) {
      switch (a.group(1)) {
        case 'start':
          start = a.group(2);
        case 'stop':
          stop = a.group(2);
        case 'channel':
          channel = a.group(2);
      }
    }
    if (start == null || stop == null || channel == null) return null;
    final s = parseXmltvDate(start);
    final e = parseXmltvDate(stop);
    if (s == null || e == null) return null;

    return EpgProgram(
      tvgId: channel,
      title: _unescape(_title.firstMatch(block)?.group(1) ?? '').trim(),
      start: s,
      stop: e,
      description: _opt(_desc.firstMatch(block)?.group(1)),
      category: _opt(_cat.firstMatch(block)?.group(1)),
      icon: _icon.firstMatch(block)?.group(1),
    );
  }

  String? _opt(String? s) {
    if (s == null) return null;
    final t = _unescape(s).trim();
    return t.isEmpty ? null : t;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '');

  /// "20261106203000 +0100" → DateTime UTC-aware convertito in locale.
  static DateTime? parseXmltvDate(String raw) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?\s*([+-]\d{4})?')
        .firstMatch(raw.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final h = int.tryParse(m.group(4) ?? '') ?? 0;
    final mi = int.tryParse(m.group(5) ?? '') ?? 0;
    final s = int.tryParse(m.group(6) ?? '') ?? 0;
    var dt = DateTime.utc(y, mo, d, h, mi, s);
    final tz = m.group(7);
    if (tz != null) {
      final sign = tz.startsWith('-') ? -1 : 1;
      final th = int.parse(tz.substring(1, 3));
      final tm = int.parse(tz.substring(3, 5));
      dt = dt.subtract(Duration(hours: sign * th, minutes: sign * tm));
    }
    return dt.toLocal();
  }
}
