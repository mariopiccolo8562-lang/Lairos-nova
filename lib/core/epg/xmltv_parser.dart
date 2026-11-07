import 'dart:convert';

import '../models/models.dart';

/// Parser XMLTV incrementale, senza DOM: file EPG da 500 MB passano in
/// streaming con memoria costante. Estrae solo i campi utili.
class XmltvStreamParser {
  // Decodifica UTF-8 a pezzi: un carattere accentato spezzato fra due blocchi di rete resta intero.
  final _text = StringBuffer();
  late ByteConversionSink _utf8 = _newDecoder();
  String _buf = '';
  /// Inizio della parte di [_buf] ancora da leggere: prima a ogni programma si ricopiava tutto il resto del buffer
  /// (lavoro quadratico: decine di GB di copie per una guida da 500 MB); ora si avanza con un indice.
  int _pos = 0;

  static final _progOpen = RegExp(
      r'<programme\s+([^>]*)>', caseSensitive: false);
  static final _attr = RegExp(r'(\w+)="([^"]*)"');
  static final _title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false);
  static final _desc = RegExp(r'<desc[^>]*>([\s\S]*?)</desc>', caseSensitive: false);
  static final _cat = RegExp(r'<category[^>]*>([\s\S]*?)</category>', caseSensitive: false);
  static final _icon = RegExp(r'<icon\s+src="([^"]*)"', caseSensitive: false);
  // compilate una volta sola (prima: due espressioni nuove per ogni data e una per ogni testo, milioni per guida)
  static final _cdata = RegExp(r'<!\[CDATA\[|\]\]>');
  static final _date = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})?(\d{2})?(\d{2})?\s*([+-]\d{4})?');

  ByteConversionSink _newDecoder() =>
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(StringConversionSink.fromStringSink(_text));

  Iterable<EpgProgram> feed(List<int> bytes) sync* {
    _utf8.add(bytes);
    final fresh = _text.toString();
    _text.clear();
    _buf = _pos > 0 ? _buf.substring(_pos) + fresh : _buf + fresh;
    _pos = 0;
    while (true) {
      final start = _buf.indexOf('<programme', _pos);
      if (start < 0) {
        // Tieni solo la coda (potrebbe contenere l'inizio di "<programme")
        _buf = _buf.length - _pos > 64 ? _buf.substring(_buf.length - 64) : _buf.substring(_pos);
        _pos = 0;
        return;
      }
      final end = _buf.indexOf('</programme>', start);
      if (end < 0) {
        _buf = _buf.substring(start);
        _pos = 0;
        return;
      }
      final block = _buf.substring(start, end + 12);
      _pos = end + 12;
      final p = _parse(block);
      if (p != null) yield p;
    }
  }

  Iterable<EpgProgram> flush() sync* {
    _buf = '';
    _pos = 0;
    _utf8 = _newDecoder();
    _text.clear();
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

  /// Entità e CDATA come prima (stesso ordine); i testi che non ne hanno (quasi tutti) non si ricopiano.
  static String _unescape(String s) {
    var t = s;
    if (t.contains('&')) {
      t = t
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'");
    }
    if (t.contains('<![CDATA[') || t.contains(']]>')) t = t.replaceAll(_cdata, '');
    return t;
  }

  /// "20261106203000 +0100" → DateTime UTC-aware convertito in locale.
  static DateTime? parseXmltvDate(String raw) {
    final m = _date.firstMatch(raw.trim());
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
