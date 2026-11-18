// Quote-aware tokenizer for the quick-add line. Pure and dependency-free.
// Ported from web/src/lib/nlp/tokenize.ts.
import 'vocab/index.dart';

/// A half-open character range [start, end) in the original line. Indices count
/// UTF-16 code units, exactly as the TypeScript original's string offsets do.
class Span {
  const Span(this.start, this.end, this.text);

  final int start;
  final int end;

  /// The original text of the range; kept so a dismissal can detect edits.
  final String text;

  @override
  bool operator ==(Object other) =>
      other is Span && other.start == start && other.end == end && other.text == text;

  @override
  int get hashCode => Object.hash(start, end, text);

  @override
  String toString() => 'Span($start, $end, "$text")';
}

class Token {
  const Token({
    required this.text,
    required this.norm,
    required this.start,
    required this.end,
    required this.quoted,
  });

  /// Original text, exactly as typed.
  final String text;

  /// Folded text used by the grammar; see `normalize`.
  final String norm;

  final int start;
  final int end;

  /// Inside a balanced pair of double quotes: never matched by any grammar.
  final bool quoted;
}

class Tokenized {
  const Tokenized({required this.tokens, required this.quoteSpans});

  final List<Token> tokens;

  /// Positions of the quote characters of balanced pairs; removed from the title.
  final List<Span> quoteSpans;
}

final RegExp _whitespace = RegExp(r'\s');

/// Split a line into whitespace-separated tokens with character spans. A balanced
/// pair of double quotes marks its content as literal: the quoted words become
/// tokens flagged `quoted`, and the quote characters themselves are reported so the
/// title builder can drop them. An unmatched quote is an ordinary character.
Tokenized tokenize(String line) {
  final tokens = <Token>[];
  final quoteSpans = <Span>[];
  final closers = _balancedQuotes(line);
  var i = 0;
  var quoted = false;
  var start = -1;
  void flush(int end) {
    if (start >= 0 && end > start) {
      final text = line.substring(start, end);
      tokens.add(Token(text: text, norm: normalize(text), start: start, end: end, quoted: quoted));
    }
    start = -1;
  }

  while (i < line.length) {
    final ch = line[i];
    if (closers.contains(i)) {
      flush(i);
      quoteSpans.add(Span(i, i + 1, ch));
      quoted = !quoted;
    } else if (_whitespace.hasMatch(ch)) {
      flush(i);
    } else if (start < 0) {
      start = i;
    }
    i++;
  }
  flush(line.length);
  return Tokenized(tokens: tokens, quoteSpans: quoteSpans);
}

/// Indices of every double quote that belongs to a balanced opening/closing pair.
Set<int> _balancedQuotes(String line) {
  final positions = <int>[];
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"') positions.add(i);
  }
  final set = <int>{};
  // Pair quotes left to right; a dangling last quote stays literal.
  for (var k = 0; k + 1 < positions.length; k += 2) {
    set.add(positions[k]);
    set.add(positions[k + 1]);
  }
  return set;
}

final RegExp _spaces = RegExp(r'\s+');

/// Build the saved title: replace every `remove` span by a word break, delete every
/// `drop` span outright (quote characters), then collapse whitespace and trim.
/// Spans may overlap or be unordered.
String stripSpans(String line, List<Span> remove, [List<Span> drop = const []]) {
  final cut = List<int>.filled(line.length, 0);
  void mark(List<Span> spans, int value) {
    for (final s in spans) {
      for (var i = s.start < 0 ? 0 : s.start; i < (s.end > line.length ? line.length : s.end); i++) {
        if (i >= 0 && i < cut.length) cut[i] = value;
      }
    }
  }

  mark(drop, 2);
  mark(remove, 1);
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    // A removed token acts as a word boundary so "milk tomorrow p2" never glues words.
    if (cut[i] == 1) {
      out.write(' ');
    } else if (cut[i] == 0) {
      out.write(line[i]);
    }
  }
  return out.toString().replaceAll(_spaces, ' ').trim();
}
