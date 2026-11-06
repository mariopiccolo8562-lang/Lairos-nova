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
