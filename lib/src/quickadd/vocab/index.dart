// The bundled vocabularies and the folding the grammar matches against.
// Ported from web/src/lib/nlp/vocab/index.ts (OpenTodo v1.5.0).
import 'de.dart';
import 'en.dart';
import 'es.dart';
import 'fr.dart';
import 'it.dart';
import 'nl.dart';
import 'pt.dart';
import 'types.dart';

export 'types.dart';

/// Every bundled vocabulary, keyed by primary language subtag.
const Map<String, Vocabulary> vocabularies = {
  'en': en,
  'de': de,
  'fr': fr,
  'it': it,
  'es': es,
  'pt': pt,
  'nl': nl,
};

final List<String> bundledLanguages = vocabularies.keys.toList();

/// Letters NFD decomposes into a base letter plus a combining mark, which
/// `normalize` then strips. Only the decompositions these seven languages use:
/// shortcut: Latin Extended-A is not listed; add it if a vocabulary needs it.
const Map<int, String> _fold = {
  0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a', 0x00E5: 'a',
  0x00E7: 'c',
  0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e',
  0x00EC: 'i', 0x00ED: 'i', 0x00EE: 'i', 0x00EF: 'i',
  0x00F1: 'n',
  0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o', 0x00F6: 'o',
  0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u',
  0x00FD: 'y', 0x00FF: 'y',
  0x00DF: 'ss',
};

/// Fold a word for matching: lower case, no diacritics, "ß" → "ss", typographic
/// apostrophes → "'". Trailing commas are dropped so "tomorrow," still matches.
String normalize(String word) {
  final out = StringBuffer();
  for (final unit in word.toLowerCase().codeUnits) {
    // A remaining combining mark (input already decomposed) is stripped like NFD's.
    if (unit >= 0x0300 && unit <= 0x036F) continue;
    final folded = _fold[unit];
    if (folded != null) {
      out.write(folded);
    } else {
      out.writeCharCode(unit);
    }
  }
  return out
      .toString()
      .replaceAll(RegExp('[‘’ʼ]'), "'")
      .replaceFirst(RegExp(r'[,;]+$'), '');
}

/// Reduce a browser language list ("de-CH", "en-US", "ja") to the bundled codes in
/// preference order, always ending with English. Unknown languages are dropped.
List<String> activeLanguages(List<String> preferred) {
  final out = <String>[];
  for (final tag in preferred) {
    final code = tag.toLowerCase().split(RegExp('[-_]')).first;
    if (vocabularies.containsKey(code) && !out.contains(code)) out.add(code);
  }
  if (!out.contains('en')) out.add('en');
  return out;
}

List<Vocabulary> vocabulariesFor(List<String> languages) =>
    activeLanguages(languages).map((code) => vocabularies[code]!).toList();
