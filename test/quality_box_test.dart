import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/quality_box.dart';

/// Riquadro della qualità nel lettore dal pannello (voce rc «qbox», contratto comune di tutte le app Kairos).
void main() {
  // tutto quello che il pannello può mandare (o non mandare) e che deve valere come oggi
  const likeToday = <Object?>['full', '', null, 'null', 'OFF', ' off', 'noq ', 'qualsiasi', 1, true];

  group('Voce «qbox»', () {
    test('solo «off» e «noq» cambiano qualcosa', () {
      expect(QualityBox.of('off'), QualityBox.off);
      expect(QualityBox.of('noq'), QualityBox.noq);
      for (final v in likeToday) {
        expect(QualityBox.of(v), QualityBox.full, reason: '«$v»');
      }
    });

    test('con «off» niente riquadro, indicatore né diagnostica', () {
      expect(QualityBox.off.shown(true), isFalse);
      expect(QualityBox.off.shown(false), isFalse);
    });

    test('il permesso «resInd» bloccato nasconde sempre tutto', () {
      for (final m in QualityBox.values) {
        expect(m.shown(false), isFalse, reason: m.name);
      }
    });

    test('con «noq» e con gli altri valori il riquadro compare', () {
      expect(QualityBox.noq.shown(true), isTrue);
      for (final v in likeToday) {
        expect(QualityBox.of(v).shown(true), isTrue, reason: '«$v»');
      }
    });
  });

  group('Testo del riquadro', () {
    test('sigle dall\'altezza', () {
      expect([for (final h in [2160, 2000, 1999, 1080, 1000, 999, 720, 700, 699, 576]) qualityTag(h)],
          ['4K', '4K', 'FHD', 'FHD', 'FHD', 'HD', 'HD', 'HD', 'SD', 'SD']);
    });

    test('come oggi', () {
      for (final v in likeToday) {
        final m = QualityBox.of(v);
        expect(qualityBoxText(1080, 50, m), 'FHD · 1080p · 50 fps');
        expect(qualityBoxText(2160, 25, m), '4K · 2160p · 25 fps');
        expect(qualityBoxText(720, 29.97, m), 'HD · 720p · 30 fps');
        expect(qualityBoxText(1080, 0, m), 'FHD · 1080p'); // FPS non ancora noti
      }
    });

    test('con «noq» senza la sigla', () {
      expect(qualityBoxText(1080, 50, QualityBox.noq), '1080p · 50 fps');
      expect(qualityBoxText(2160, 25, QualityBox.noq), '2160p · 25 fps');
      expect(qualityBoxText(720, 59.94, QualityBox.noq), '720p · 60 fps');
      expect(qualityBoxText(576, 0, QualityBox.noq), '576p');
    });

    test('mai « · » doppi, all\'inizio o alla fine', () {
      for (final m in QualityBox.values) {
        for (final h in [480, 576, 720, 1080, 2160]) {
          for (final f in [0.0, -1.0, 25.0, 59.94, double.nan, double.infinity]) {
            final t = qualityBoxText(h, f, m);
            // ogni parte fra due « · » c'è davvero: niente parti vuote, quindi niente « · » doppi né ai bordi
            expect(t.split(' · ').every((p) => p.isNotEmpty && p == p.trim()), isTrue, reason: '«$t»');
          }
        }
      }
    });

    test('senza altezza nessun riquadro', () {
      for (final m in QualityBox.values) {
        expect(qualityBoxText(0, 50, m), '');
        expect(qualityBoxText(-1, 0, m), '');
      }
    });
  });

  group('Indicatore e diagnostica', () {
    test('indicatore nella barra: con «noq» le righe al posto della sigla', () {
      expect(qualityBadgeText('FHD', 1080, QualityBox.full), 'FHD');
      expect(qualityBadgeText('—', 0, QualityBox.full), '—');
      expect(qualityBadgeText('FHD', 1080, QualityBox.noq), '1080p');
      expect(qualityBadgeText('4K', 2160, QualityBox.noq), '2160p');
      expect(qualityBadgeText('—', 0, QualityBox.noq), '—');
    });

    test('diagnostica: con «noq» tolta solo la sigla', () {
      const rest = '1920×1080 · 50 fps · h264 · mediacodec';
      expect(qualityDiagText('FHD', rest, QualityBox.full), 'FHD $rest');
      expect(qualityDiagText('FHD', rest, QualityBox.noq), rest);
      expect(qualityDiagText('', rest, QualityBox.full), rest);
    });
  });
}
