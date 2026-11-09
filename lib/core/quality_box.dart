// Riquadro della qualità nel lettore («FHD · 1080p · 50 fps» in alto a destra sui canali in diretta): come lo vedono i
// clienti lo decide il pannello, per tutte le app Kairos insieme, con la voce rc «qbox» del controllo remoto.
// - «off»: il riquadro non compare mai (né all'apertura del canale, né al cambio di risoluzione, né con la barra
//   informazioni) e con lui l'indicatore della qualità nella barra e la diagnostica, come con il permesso «resInd»
//   bloccato; nelle Impostazioni sparisce l'interruttore «Overlay diagnostica».
// - «noq»: tutto resta, senza la sigla di qualità (4K, UHD, FHD, HD, SD): «1080p · 50 fps».
// - «full», vuota, assente o qualsiasi altro valore: come sempre.
// Il permesso «resInd» bloccato nasconde comunque tutto. Nomi dei canali, avvisi, qualità adattiva e dati per il
// pannello non cambiano. Logica pura, provata in test/quality_box_test.dart.

/// Come i clienti vedono il riquadro della qualità (voce rc «qbox» del pannello).
enum QualityBox {
  /// come sempre: «FHD · 1080p · 50 fps»
  full,

  /// senza la sigla di qualità: «1080p · 50 fps»
  noq,

  /// mai, come con il permesso «resInd» bloccato
  off;

  /// La voce così come arriva dal pannello: cambiano qualcosa solo «off» e «noq», il resto (null e vuoto compresi) è [full].
  static QualityBox of(Object? rcValue) => switch (rcValue?.toString()) {
        'off' => off,
        'noq' => noq,
        _ => full,
      };

  /// Riquadro, indicatore e diagnostica possono comparire: permesso «resInd» non bloccato e voce diversa da «off».
  bool shown(bool resIndPerm) => resIndPerm && this != off;

  /// Con la sigla di qualità (voce diversa da «noq»).
  bool get tag => this != noq;
}

/// Sigla di qualità del riquadro dall'altezza del video.
String qualityTag(int height) => height >= 2000 ? '4K' : (height >= 1000 ? 'FHD' : (height >= 700 ? 'HD' : 'SD'));

/// Testo del riquadro: «FHD · 1080p · 50 fps», con «noq» «1080p · 50 fps»; FPS omessi finché non sono noti.
/// Le parti vuote si saltano: mai « · » doppi, all'inizio o alla fine. Altezza non nota: '' (nessun riquadro).
String qualityBoxText(int height, double fps, QualityBox mode) {
  if (height <= 0) return '';
  return [
    if (mode.tag) qualityTag(height),
    '${height}p',
    if (fps > 0 && fps.isFinite) '${fps.round()} fps',
  ].join(' · ');
}

/// Indicatore della qualità nella barra in alto: la sigla [tag] («FHD», «—» se non nota); con «noq» le righe («1080p»).
String qualityBadgeText(String tag, int height, QualityBox mode) => mode.tag ? tag : (height > 0 ? '${height}p' : '—');

/// Prima riga della diagnostica: la sigla [tag] e poi [rest] («FHD 1920×1080 · 50 fps · h264»); con «noq» solo [rest].
String qualityDiagText(String tag, String rest, QualityBox mode) => mode.tag && tag.isNotEmpty ? '$tag $rest' : rest;
