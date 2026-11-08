/// Controlli a distanza dal pannello senza avvisi al cliente.
///
/// «Reimposta PIN controllo genitori»: il PIN torna 0000 senza nessun messaggio sul «fornitore», ma il blocco non
/// resta spento in silenzio: l'app chiede subito di sceglierne uno nuovo (stessa finestra della prima installazione,
/// con «Più tardi»). Se il reset arriva durante la visione (schermo intero o anteprima) la richiesta aspetta la fine.
class PinAsk {
  bool _pending = false;

  /// Reset arrivato durante la visione: la scelta del PIN si chiederà a visione finita.
  bool get pending => _pending;

  /// PIN reimpostato dal pannello. `true` = chiedere subito il nuovo PIN; durante la visione resta in attesa.
  bool onReset({required bool watching}) {
    _pending = watching;
    return !watching;
  }

  /// Visione finita. `true` = c'era un reset in attesa: chiedere ora il nuovo PIN (una volta sola).
  bool onViewEnd() {
    if (!_pending) return false;
    _pending = false;
    return true;
  }
}
