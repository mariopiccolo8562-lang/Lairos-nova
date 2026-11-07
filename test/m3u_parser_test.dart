import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/epg/xmltv_parser.dart';
import 'package:kairos_nova/core/m3u/m3u_parser.dart';
import 'package:kairos_nova/core/models/models.dart';

void main() {
  test('parser M3U: attributi, gruppi, header VLC, chunk spezzati', () {
    const src = '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="sky.sport" tvg-name="Sky Sport" tvg-logo="http://x/l.png" group-title="Sport" tvg-chno="201",Sky Sport F1 HD\n'
        '#EXTVLCOPT:http-user-agent=TestUA\n'
        'http://host/live/1.m3u8\n'
        '#EXTINF:-1 group-title="Film",Inception (2010)\n'
        'http://host/movie/55.mkv\n'
        '#EXTINF:-1 group-title="Serie",Dark S01E01\n'
        'http://host/series/9.mp4\n';
    final bytes = utf8.encode(src);
    final parser = M3uStreamParser();
    final out = <M3uEntry>[];
    // Alimenta a chunk di 7 byte per simulare lo streaming di rete
    for (var i = 0; i < bytes.length; i += 7) {
      out.addAll(parser.feed(bytes.sublist(i, (i + 7).clamp(0, bytes.length))));
    }
    out.addAll(parser.flush());

    expect(out.length, 3);
    expect(out[0].name, 'Sky Sport F1 HD');
    expect(out[0].tvgId, 'sky.sport');
    expect(out[0].group, 'Sport');
    expect(out[0].number, 201);
    expect(out[0].headers?['User-Agent'], 'TestUA');
    expect(out[0].type, ChannelType.live);
    expect(out[1].type, ChannelType.movie);
    expect(out[2].type, ChannelType.series);
  });

  test('parser M3U: accenti spezzati fra due blocchi restano interi; gruppi radio e serie riconosciuti', () {
    const src = '#EXTM3U\n'
        '#EXTINF:-1 group-title="Città",Rai Più Città è\n'
        'http://host/live/7.ts\n'
        '#EXTINF:-1 group-title="Radio Italia",RTL 102.5\n'
        'http://host/live/8.ts\n'
        '#EXTINF:-1 group-title="Serie TV Stagione 1",Episodio 1\n'
        'http://host/vod/9.mp4\n'
        '#EXTINF:-1 group-title="Radio Italia",Radio Uno\n'
        'http://host/live/10.ts';
    final bytes = utf8.encode(src);
    for (final size in [1, 2, 3, 5, 64]) {
      final parser = M3uStreamParser();
      final out = <M3uEntry>[];
      for (var i = 0; i < bytes.length; i += size) {
        out.addAll(parser.feed(bytes.sublist(i, (i + size).clamp(0, bytes.length))));
      }
      out.addAll(parser.flush());
      expect(out.length, 4, reason: 'blocchi da $size byte');
      expect(out[0].name, 'Rai Più Città è', reason: 'blocchi da $size byte');
      expect(out[0].group, 'Città');
      expect(out[0].type, ChannelType.live);
      expect(out[1].type, ChannelType.radio);
      expect(out[2].type, ChannelType.series);
      expect(out[3].type, ChannelType.radio);
      expect(out[3].url, 'http://host/live/10.ts');
    }
  });

  test('parser XMLTV: molti programmi per blocco, blocchi spezzati, accenti, entità e CDATA', () {
    final sb = StringBuffer('<?xml version="1.0"?><tv><channel id="x"><display-name>X</display-name></channel>');
    for (var i = 0; i < 40; i++) {
      sb.write('<programme start="20261106${(10 + i % 10).toString()}0000 +0100" stop="20261106${(10 + i % 10).toString()}3000 +0100" '
          'channel="ch$i"><title lang="it">Città n.$i &amp; più</title>'
          '<desc><![CDATA[Descrizione è $i]]></desc></programme>\n');
    }
    sb.write('</tv>');
    final bytes = utf8.encode(sb.toString());
    for (final size in [1, 7, 100, 4096, bytes.length]) {
      final p = XmltvStreamParser();
      final progs = <EpgProgram>[];
      for (var i = 0; i < bytes.length; i += size) {
        progs.addAll(p.feed(bytes.sublist(i, (i + size).clamp(0, bytes.length))));
      }
      progs.addAll(p.flush());
      expect(progs.length, 40, reason: 'blocchi da $size byte');
      expect(progs[3].tvgId, 'ch3');
      expect(progs[3].title, 'Città n.3 & più', reason: 'blocchi da $size byte');
      expect(progs[3].description, 'Descrizione è 3');
      expect(progs[3].duration.inMinutes, 30);
      expect(progs.last.tvgId, 'ch39');
    }
  });

  test('parser XMLTV: date con fuso e programmi', () {
    const xml = '<tv><programme start="20261106203000 +0100" stop="20261106223000 +0100" channel="sky.sport">'
        '<title lang="it">Gran Premio</title><desc>Gara &amp; podio</desc><category>Sport</category></programme></tv>';
    final p = XmltvStreamParser();
    final progs = [...p.feed(utf8.encode(xml)), ...p.flush()];
    expect(progs.length, 1);
    expect(progs.first.title, 'Gran Premio');
    expect(progs.first.description, 'Gara & podio');
    expect(progs.first.duration.inMinutes, 120);
    expect(progs.first.start.toUtc().hour, 19);
  });
}
