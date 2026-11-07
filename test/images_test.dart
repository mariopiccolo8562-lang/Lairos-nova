import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/device_tier.dart';
import 'package:kairos_nova/core/images.dart';

void main() {
  test('locandine TMDB alla misura della vista, mai più grandi del link; altri indirizzi invariati', () {
    const orig = 'https://image.tmdb.org/t/p/original/abc.jpg';
    expect(tmdbSized(orig, 300), 'https://image.tmdb.org/t/p/w342/abc.jpg');
    expect(tmdbSized(orig, 112), 'https://image.tmdb.org/t/p/w185/abc.jpg');
    expect(tmdbSized(orig, 300, weak: true), 'https://image.tmdb.org/t/p/w185/abc.jpg');
    expect(tmdbSized('http://image.tmdb.org/t/p/w600_and_h900_bestv2/x.jpg', 380),
        'http://image.tmdb.org/t/p/w342/x.jpg');
    expect(tmdbSized('https://image.tmdb.org/t/p/w500/x.jpg?a=1', 300), 'https://image.tmdb.org/t/p/w342/x.jpg?a=1');
    expect(tmdbSized('https://image.tmdb.org/t/p/h632/x.jpg', 100), 'https://image.tmdb.org/t/p/w185/x.jpg');
    // già piccole: restano come sono
    expect(tmdbSized('https://image.tmdb.org/t/p/w154/x.jpg', 300), 'https://image.tmdb.org/t/p/w154/x.jpg');
    expect(tmdbSized('https://image.tmdb.org/t/p/w342/x.jpg', 300), 'https://image.tmdb.org/t/p/w342/x.jpg');
    expect(tmdbSized('https://image.tmdb.org/t/p/w185/x.jpg', 300, weak: true), 'https://image.tmdb.org/t/p/w185/x.jpg');
    // non TMDB o senza misura: invariati
    expect(tmdbSized('http://server.tv/logo/rai1.png', 300), 'http://server.tv/logo/rai1.png');
    expect(tmdbSized('https://image.tmdb.org/t/p/', 300), 'https://image.tmdb.org/t/p/');
  });

  test('classe D (debole): ≤ 1,2 GB, low RAM, Android < 7 o modello low-end; senza dati non debole', () {
    expect(DeviceTier.isWeak(totalMemMb: 950), isTrue); // Fire TV Stick Lite
    expect(DeviceTier.isWeak(totalMemMb: 1228), isTrue);
    expect(DeviceTier.isWeak(totalMemMb: 1400, sdk: 28), isFalse); // Fire TV Stick 4K
    expect(DeviceTier.isWeak(totalMemMb: 3800, sdk: 22), isTrue);
    expect(DeviceTier.isWeak(lowRam: true, totalMemMb: 2000), isTrue);
    expect(DeviceTier.isWeak(model: ' aftss '), isTrue);
    expect(DeviceTier.isWeak(), isFalse);
    DeviceTier.init(const {'totalMemMb': 1024, 'sdk': 28, 'model': 'AFTKA'});
    expect(DeviceTier.weak, isTrue);
    DeviceTier.init(const <String, dynamic>{});
    expect(DeviceTier.weak, isFalse);
    DeviceTier.init(null);
    expect(DeviceTier.weak, isFalse);
  });
}
