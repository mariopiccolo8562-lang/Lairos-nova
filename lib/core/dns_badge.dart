/// Lucchetto del DNS cifrato accanto alla «K» della barra (sul telefono nella Home, in alto a destra) (13 novembre 2026): dice a colpo d'occhio se il DNS cifrato
/// acceso dal fornitore (voce «sdns» del pannello) è attivo. Verde = attivo; giallo = non partito (permesso da
/// confermare o negato, un'altra VPN accesa, errore); bianco tenue = in avvio. Logica pura, senza Flutter.
abstract final class DnsBadge {
  /// Stato da mostrare: vuoto = niente lucchetto (il fornitore non lo ha acceso, o abbonamento non attivo).
  static String state(bool wanted, String service) => !wanted ? '' : (service.isEmpty ? 'off' : service);

  static bool on(String state) => state == 'on';

  /// Non è partito e serve attenzione (giallo); «off» = sta partendo.
  static bool warn(String state) => state.isNotEmpty && state != 'on' && state != 'off';

  /// Colore ARGB del lucchetto.
  static int color(String state) => on(state) ? 0xFF2EE59D : (warn(state) ? 0xFFF5B041 : 0xCCFFFFFF);

  /// Frase per chi usa la lettura dello schermo.
  static String text(String state) => switch (state) {
        '' => '',
        'on' => 'DNS cifrato attivo',
        'asking' => 'DNS cifrato: da confermare',
        'denied' => 'DNS cifrato: permesso negato',
        'other' => 'DNS cifrato: altra VPN accesa',
        'error' => 'DNS cifrato non attivo',
        _ => 'DNS cifrato in avvio',
      };
}
