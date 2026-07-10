/// Utility di normalizzazione replicate 1:1 da js/auth.js (spec-data §2.10).
library;

/// Normalizza un numero di telefono in E.164 (default Italia).
String normalizePhone(String raw) {
  var s = raw.replaceAll(RegExp(r'[\s\-().]'), '');
  if (s.isEmpty) return s;
  if (s.startsWith('+')) return s;
  if (s.startsWith('00')) return '+${s.substring(2)}';
  if (s.startsWith('0')) return '+39${s.substring(1)}';
  if (RegExp(r'^\d{9,10}$').hasMatch(s)) return '+39$s';
  return s;
}

const _comuneConnectives = {
  'di',
  'del',
  'dei',
  'della',
  'delle',
  'dello',
  'degli',
  'da',
  'dal',
  'dai',
  'dalle',
  'dagli',
  'dallo',
  'in',
  'nel',
  'nei',
  'nella',
  'nelle',
  'nello',
  'negli',
  'a',
  'ai',
  'al',
  'alla',
  'alle',
  'allo',
  'agli',
  'e',
  'ed',
  'con',
  'su',
  'sul',
  'sui',
  'sulla',
  'sulle',
  'sullo',
  'sugli',
  'per',
  'tra',
  'fra',
  'la',
  'le',
  'lo',
  'il',
  'i',
  'gli',
  'l',
};

// Prefissi con apostrofo, dal più lungo al più corto (match greedy).
const _comuneAposPrefixes = [
  "dell'",
  "nell'",
  "sull'",
  "dall'",
  "all'",
  "d'",
  "l'",
];

/// Title-case italiano per i comuni, replicata identica a normalize_comune()
/// (SQL, migration 0026): es. "sant'ambrogio di valpolicella" →
/// "Sant'Ambrogio di Valpolicella", "dell'olio" → "dell'Olio".
String normalizeComune(String input) {
  var s = input.replaceAll(RegExp("[’‘ʼ]"), "'").trim();
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return s;
  s = s.toLowerCase();

  final words = s.split(' ');
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (i > 0 && _comuneConnectives.contains(w)) {
      out.add(w);
      continue;
    }
    if (i > 0) {
      final prefix = _comuneAposPrefixes
          .where((p) => w.startsWith(p) && w.length > p.length)
          .fold<String?>(
            null,
            (best, p) => best == null || p.length > best.length ? p : best,
          );
      if (prefix != null) {
        out.add(prefix + _capitalizeSegments(w.substring(prefix.length)));
        continue;
      }
    }
    out.add(_capitalizeSegments(w));
  }
  return out.join(' ');
}

/// Maiuscola a inizio parola e dopo apostrofo/trattino.
String _capitalizeSegments(String word) {
  final buf = StringBuffer();
  var upperNext = true;
  for (final ch in word.split('')) {
    if (upperNext && RegExp(r'[a-zà-ÿ]').hasMatch(ch)) {
      buf.write(ch.toUpperCase());
      upperNext = false;
    } else {
      buf.write(ch);
      if (ch == "'" || ch == '-') upperNext = true;
    }
  }
  return buf.toString();
}

/// Capitalizza ogni parola di un nome (prima maiuscola, resto minuscolo),
/// come fa registerUser nel web.
String capitalizeName(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
    .join(' ');

/// Anagrafica completa: whatsapp, CF e indirizzo tutti valorizzati.
bool isAnagraficaComplete({
  String? whatsapp,
  String? codiceFiscale,
  String? indirizzoVia,
  String? indirizzoPaese,
  String? indirizzoCap,
}) {
  bool ok(String? v) => v != null && v.trim().isNotEmpty;
  return ok(whatsapp) &&
      ok(codiceFiscale) &&
      ok(indirizzoVia) &&
      ok(indirizzoPaese) &&
      ok(indirizzoCap);
}
