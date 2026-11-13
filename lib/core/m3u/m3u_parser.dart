import 'dart:convert';

import '../models/models.dart';

/// Voce M3U grezza prodotta dal parser (una per #EXTINF + URL).
class M3uEntry {
  M3uEntry({
    required this.name,
    required this.url,
    this.group = '',
    this.logo,
    this.tvgId,
    this.number,
    this.catchupDays = 0,
    this.headers,
    required this.type,
  });

  final String name;
  final String url;
  final String group;
  final String? logo;
  final String? tvgId;
  final int? number;
  final int catchupDays;
  final Map<String, String>? headers;
  final ChannelType type;
}

/// Parser M3U/M3U8 incrementale: riceve chunk di byte, emette entry complete.
///
/// - Non carica mai il file intero in memoria.
/// - Tollera CRLF, BOM, righe spezzate, attributi senza virgolette.
/// - Gestisce #EXTGRP, #EXTVLCOPT (header HTTP), #KODIPROP, catchup.
/// - Classifica live / film / serie / radio da attributi e URL.
class M3uStreamParser {
  // Decodifica UTF-8 a pezzi: un carattere accentato spezzato fra due blocchi di rete resta intero (prima
  // diventava «�», e il nome del canale, quindi anche la chiave dei preferiti, poteva cambiare a ogni import).
  final _text = StringBuffer();
  late ByteConversionSink _utf8 = _newDecoder();
  String _carry = '';
  bool _headerSeen = false;

  /// Gruppi già classificati (serie / radio dal nome del gruppo): lo stesso gruppo si ripete per migliaia di voci.
  final _groupKinds = <String, int>{};

  // Stato della voce in costruzione
  String? _name;
  String _group = '';
  String? _logo;
  String? _tvgId;
  int? _number;
  int _catchup = 0;
  Map<String, String>? _headers;
  String? _typeHint;

  static final _attrRe = RegExp(r'([A-Za-z0-9\-_]+)=(?:"([^"]*)"|([^\s,]+))');

  ByteConversionSink _newDecoder() =>
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(StringConversionSink.fromStringSink(_text));

  String _takeText() {
    final s = _text.toString();
    _text.clear();
    return s;
  }

  Iterable<M3uEntry> feed(List<int> bytes) sync* {
    _utf8.add(bytes);
    final text = _carry + _takeText();
    final lastNl = text.lastIndexOf('\n');
    if (lastNl < 0) {
      _carry = text;
      return;
    }
    _carry = text.substring(lastNl + 1);
    final block = text.substring(0, lastNl);
    for (final raw in block.split('\n')) {
      final e = _line(raw);
      if (e != null) yield e;
    }
  }

  Iterable<M3uEntry> flush() sync* {
    // fine del flusso: un eventuale carattere rimasto a metà diventa «�» come prima; il parser resta riusabile
    _utf8.close();
    _carry += _takeText();
    _utf8 = _newDecoder();
    if (_carry.isNotEmpty) {
      final e = _line(_carry);
      _carry = '';
      if (e != null) yield e;
    }
  }

  M3uEntry? _line(String raw) {
    var line = raw.trimRight();
    if (line.isEmpty) return null;
    if (!_headerSeen) {
      line = line.replaceFirst('﻿', '');
      _headerSeen = true;
    }

    if (line.startsWith('#EXTINF')) {
      _parseExtinf(line);
      return null;
    }
    if (line.startsWith('#EXTGRP:')) {
      _group = line.substring(8).trim();
      return null;
    }
    if (line.startsWith('#EXTVLCOPT:')) {
      _parseVlcOpt(line.substring(11));
      return null;
    }
    if (line.startsWith('#KODIPROP:')) {
      _parseKodiProp(line.substring(10));
      return null;
    }
    if (line.startsWith('#')) return null;

    // Riga URL
    if (_name == null) return null;
    final url = line.trim();
    if (url.isEmpty) {
      _reset();
      return null;
    }
    if (hideSepNames && isSepName(_name!)) {
      _reset();
      return null;
    }
    final entry = M3uEntry(
      name: _name!,
      url: url,
      group: _group,
      logo: _logo,
      tvgId: _tvgId,
      number: _number,
      catchupDays: _catchup,
      headers: _headers,
      type: _classify(url, _group, _typeHint),
    );
    _reset();
    return entry;
  }

  void _parseExtinf(String line) {
    final comma = _lastCommaOutsideQuotes(line);
    final attrPart = comma < 0 ? line : line.substring(0, comma);
    final title = comma < 0 ? '' : line.substring(comma + 1).trim();

    String? tvgName;
    for (final m in _attrRe.allMatches(attrPart)) {
      final key = m.group(1)!.toLowerCase();
      final val = (m.group(2) ?? m.group(3) ?? '').trim();
      switch (key) {
        case 'tvg-id':
          _tvgId = val.isEmpty ? null : val;
        case 'tvg-name':
          tvgName = val;
        case 'tvg-logo':
          _logo = val.isEmpty ? null : val;
        case 'group-title':
          _group = val;
        case 'tvg-chno':
        case 'channel-number':
          _number = int.tryParse(val);
        case 'catchup-days':
          _catchup = int.tryParse(val) ?? 0;
        case 'catchup':
          if (_catchup == 0 && val.isNotEmpty) _catchup = 1;
        case 'tvg-type':
        case 'type':
          _typeHint = val.toLowerCase();
        case 'radio':
          if (val == 'true') _typeHint = 'radio';
      }
    }
    _name = title.isNotEmpty ? title : (tvgName ?? 'Senza nome');
  }

  static int _lastCommaOutsideQuotes(String s) {
    var inQ = false;
    var last = -1;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x22) inQ = !inQ;
      if (c == 0x2C && !inQ) last = i;
    }
    return last;
  }

  void _parseVlcOpt(String opt) {
    final eq = opt.indexOf('=');
    if (eq < 0) return;
    final k = opt.substring(0, eq).trim().toLowerCase();
    final v = opt.substring(eq + 1).trim();
    _headers ??= {};
    switch (k) {
      case 'http-user-agent':
        _headers!['User-Agent'] = v;
      case 'http-referrer':
      case 'http-referer':
        _headers!['Referer'] = v;
      case 'http-origin':
        _headers!['Origin'] = v;
    }
  }

  void _parseKodiProp(String prop) {
    final eq = prop.indexOf('=');
    if (eq < 0) return;
    final k = prop.substring(0, eq).trim().toLowerCase();
    final v = prop.substring(eq + 1).trim();
    if (k == 'inputstream.adaptive.stream_headers') {
      _headers ??= {};
      for (final kv in v.split('&')) {
        final i = kv.indexOf('=');
        if (i > 0) {
          _headers![kv.substring(0, i)] = Uri.decodeComponent(kv.substring(i + 1));
        }
      }
    }
  }

  static final _movieExt = RegExp(r'\.(mp4|mkv|avi|mov|m4v|wmv|flv|webm)(\?|$)', caseSensitive: false);
  static final _seriesRe = RegExp(r'\bS\d{1,2}\s?E\d{1,3}\b|/series/|\bseason\b|\bstagione\b', caseSensitive: false);
  static final _radioRe = RegExp(r'\bradio\b|\bfm\b|/radio/', caseSensitive: false);

  ChannelType _classify(String url, String group, String? hint) {
    if (hint == 'radio') return ChannelType.radio;
    if (hint == 'movie' || hint == 'vod') return ChannelType.movie;
    if (hint == 'series') return ChannelType.series;
    final g = _groupKind(group);
    if ((g & 1) != 0 || _seriesRe.hasMatch(url)) return ChannelType.series;
    if (url.contains('/movie/') || _movieExt.hasMatch(url)) return ChannelType.movie;
    if ((g & 2) != 0) return ChannelType.radio;
    return ChannelType.live;
  }

  /// 1 = il nome del gruppo dice «serie», 2 = dice «radio» (stesse espressioni di prima, calcolate una volta).
  int _groupKind(String group) {
    final known = _groupKinds[group];
    if (known != null) return known;
    if (_groupKinds.length >= 20000) _groupKinds.clear();
    final kind = (_seriesRe.hasMatch(group) ? 1 : 0) | (_radioRe.hasMatch(group) ? 2 : 0);
    _groupKinds[group] = kind;
    return kind;
  }

  void _reset() {
    _name = null;
    _group = '';
    _logo = null;
    _tvgId = null;
    _number = null;
    _catchup = 0;
    _headers = null;
    _typeHint = null;
  }
}

/// Titoli «----NOME----», «##### SPORT #####», «★★★ CINEMA ★★★»: separatori del fornitore, non canali né film né
/// serie (non si aprono) → non si mostrano. Stessa regola di Kairos Pro; «...E giustizia per tutti» resta.
final RegExp _rxSep = RegExp(r'^[\s\-—=#*_~▬═━─•●◆★☆✦|+<>]{3,}|^[\s\-—=#*_~▬═━─•●◆★☆✦|+<>.:]{2,}.*[\-—=#*_~▬═━─•●◆★☆✦|+<>]{2,}\s*$');
final RegExp _rxSep4 = RegExp(r'[\-—=#▬═━─_*~]{4,}');
final RegExp _rxAlnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
/// voce «o.sep» del pannello (off = i separatori si vedono); la imposta il servizio del pannello
bool hideSepNames = true;
bool isSepName(String raw) {
  final n = raw.trim();
  if (n.isEmpty) return true;
  if (_rxSep4.hasMatch(n)) return true;
  return _rxSep.hasMatch(n) && _rxAlnum.allMatches(n).length < n.length * 0.85;
}
