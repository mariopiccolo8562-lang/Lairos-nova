/// Classe del dispositivo per la grafica e la memoria: «debole» = classe D di Kairos Adaptive v1 (memoria ≤ 1,2 GB,
/// sistema «low RAM», Android < 7 o modello low-end noto: Fire TV Stick 1ª/2ª gen, Stick Lite, Fire TV 1ª gen).
/// Si calcola una volta all'avvio, prima del primo fotogramma, dai dati della parte nativa; senza dati (iOS, errore)
/// resta «non debole», cioè come prima. Il valore «dev» del battito al pannello non cambia (si calcola come sempre).
class DeviceTier {
  DeviceTier._();

  /// Dispositivo debole: niente sfocature né animazioni continue, cache delle immagini più piccole.
  static bool weak = false;

  /// Modelli low-end noti (gli stessi della classe «dev» del battito).
  static const Set<String> _lowEndModels = {'AFTM', 'AFTT', 'AFTSS', 'AFTB'};

  /// Regola della classe D: ≤ 1,2 GB (1228 MB), «low RAM», Android < 7 (SDK 24) o modello low-end noto.
  static bool isWeak({int totalMemMb = 0, bool lowRam = false, int sdk = 0, String model = ''}) =>
      lowRam ||
      (totalMemMb > 0 && totalMemMb <= 1228) ||
      (sdk > 0 && sdk < 24) ||
      _lowEndModels.contains(model.trim().toUpperCase());

  /// Dati della parte nativa ({sdk, model, lowRam, totalMemMb, …}); mappa vuota = classe invariata (non debole).
  static void init(Object? info) {
    final m = info is Map ? info : const {};
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    weak = isWeak(
      totalMemMb: asInt(m['totalMemMb']),
      lowRam: m['lowRam'] == true,
      sdk: asInt(m['sdk']),
      model: (m['model'] ?? '').toString(),
    );
  }
}
