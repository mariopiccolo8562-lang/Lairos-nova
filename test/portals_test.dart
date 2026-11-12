import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/db/kairos_db.dart';
import 'package:kairos_nova/core/models/models.dart';
import 'package:kairos_nova/core/panel/panel_client.dart';
import 'package:kairos_nova/core/panel/portals.dart';

void main() {
  test('FNV-1a offsets match the Kotlin UTF-16 vectors', () {
    for (final (code, expected) in <(String, List<int>)>[
      ('ABC123', [1, 0, 1]),
      ('K7Q2ZP', [0, 2, 2]),
      ('', [1, 0, 1]),
      ('000000', [1, 2, 1]),
    ]) {
      expect([2, 3, 4].map((n) => PortalRotation.offset(code, n)), expected);
    }
  });

  test('selection supports modes and healthy saved choices', () {
    const candidates = ['http://main.test', 'https://alt1.test', 'http://alt2.test'];
    const now = 1000;
    expect(PortalRotation.select(mode: 'main', candidates: candidates, code: 'ABC123', nowMs: now), candidates.first);
    expect(PortalRotation.select(mode: 'alt', candidates: candidates, code: 'ABC123', nowMs: now), candidates[1]);
    expect(PortalRotation.select(mode: 'auto', candidates: candidates, code: '', nowMs: now), candidates.first);
    expect(
      PortalRotation.select(
        mode: 'auto',
        candidates: candidates,
        code: '',
        savedChoice: candidates[2],
        nowMs: now,
      ),
      candidates[2],
    );
    expect(
      PortalRotation.select(
        mode: 'auto',
        candidates: candidates,
        code: '',
        savedChoice: candidates[2],
        badUntil: {PortalRotation.hostKey(candidates[2]): 2000},
        nowMs: now,
      ),
      candidates.first,
    );
    expect(
      PortalRotation.select(mode: 'rot', candidates: candidates, code: 'ABC123', nowMs: now),
      PortalRotation.order(candidates, 'ABC123').first,
    );
    expect(
      PortalRotation.select(
        mode: 'rot',
        candidates: candidates,
        code: 'ABC123',
        savedChoice: candidates[1],
        nowMs: now,
      ),
      candidates[1],
    );
    final rotated = PortalRotation.order(candidates, 'ABC123');
    expect(
      PortalRotation.select(
        mode: 'rot',
        candidates: candidates,
        code: 'ABC123',
        savedChoice: rotated.first,
        badUntil: {PortalRotation.hostKey(rotated.first): 2000},
        nowMs: now,
      ),
      rotated.skip(1).first,
    );
  });

  test('next advances in mode order and skips unhealthy candidates', () {
    const candidates = ['http://main.test', 'https://alt1.test', 'http://alt2.test'];
    const now = 1000;
    expect(
      PortalRotation.next(mode: 'auto', candidates: candidates, code: '', current: candidates.first, nowMs: now),
      candidates[1],
    );
    expect(
      PortalRotation.next(
        mode: 'auto',
        candidates: candidates,
        code: '',
        current: candidates.first,
        badUntil: {PortalRotation.hostKey(candidates[1]): 2000},
        nowMs: now,
      ),
      candidates[2],
    );
    final rotated = PortalRotation.order(candidates, 'ABC123');
    expect(
      PortalRotation.next(mode: 'rot', candidates: candidates, code: 'ABC123', current: rotated.first, nowMs: now),
      rotated[1],
    );
    expect(PortalRotation.next(mode: 'main', candidates: candidates, code: '', current: candidates.first), isNull);
  });

  test('playlist fields, URL-origin rewrite, and old signature migration', () {
    final playlist = PanelPlaylist.fromJson({
      'id': 'p1',
      'name': 'Provider',
      'type': 'm3u',
      'url': 'http://main.test/get.php?username=u&password=p&type=m3u_plus',
      'host': 'http://main.test',
      'alts': ['https://alt.test'],
      'altNames': ['Reserve'],
      'mainName': 'Main',
      'mode': 'rot',
    });
    expect(playlist.alts, ['https://alt.test']);
    expect(playlist.altNames, ['Reserve']);
    expect(playlist.mainName, 'Main');
    expect(playlist.mode, 'rot');
    expect(
      PortalRotation.candidates(
        host: 'main.test/',
        url: '',
        alts: ['https://ALT.test/path/', 'https://alt.test', 'alt2.test'],
      ),
      ['http://main.test', 'https://alt.test', 'http://alt2.test'],
    );
    expect(playlist.sourceFor('https://alt.test'), 'https://alt.test/get.php?username=u&password=p&type=m3u_plus');
    expect(
      PortalRotation.replaceOrigin('http://main.test/live/u/p/1.ts', 'https://alt.test'),
      'https://alt.test/live/u/p/1.ts',
    );
    final oldPlaylist = PanelPlaylist.fromJson({
      'id': 'xt',
      'name': 'Xtream',
      'type': 'xtream',
      'host': 'http://main.test/',
      'username': 'u',
      'password': 'p',
      'mode': 'invalid',
    });
    expect(oldPlaylist.mode, 'auto');
    final storedOldSignature = oldPlaylist.legacySignatureForSource(oldPlaylist.server);
    expect(
      PortalRotation.signaturesMatch(storedOldSignature, oldPlaylist.signature, oldPlaylist.legacySignatureForSource(oldPlaylist.server)),
      isTrue,
    );
    expect(
      PortalRotation.signaturesMatch('other', oldPlaylist.signature, oldPlaylist.legacySignatureForSource(oldPlaylist.server)),
      isFalse,
    );
  });

  test('source-only update keeps the playlist row instead of reimporting', () {
    final dir = Directory.systemTemp.createTempSync('nova-portals-');
    final db = KairosDb.openAtPath('${dir.path}/test.db');
    addTearDown(() {
      db.close();
      dir.deleteSync(recursive: true);
    });
    final id = db.insertPlaylist(
      name: 'Provider',
      kind: PlaylistKind.xtream,
      source: 'http://main.test',
      username: 'u',
      password: 'p',
      epgUrl: 'http://main.test/xmltv.php',
    );
    db.updatePlaylistSource(id, source: 'https://alt.test', epgUrl: 'https://alt.test/xmltv.php');
    expect(db.playlist(id)?.source, 'https://alt.test');
    expect(db.playlist(id)?.epgUrl, 'https://alt.test/xmltv.php');
    expect(db.playlists().map((playlist) => playlist.id), [id]);
  });
}
