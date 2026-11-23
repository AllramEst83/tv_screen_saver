/// Result of parsing a `Range` header against a file size.
sealed class RangeResult {
  const RangeResult();
}

/// No usable range: serve the whole file with 200. Used for a missing header,
/// a malformed one, a non-`bytes` unit, and multi-range requests (we choose to
/// ignore multi-range and answer 200 with the full file).
class FullRange extends RangeResult {
  const FullRange();
}

/// A satisfiable single range, inclusive on both ends.
class SingleRange extends RangeResult {
  const SingleRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
}

/// The range cannot be satisfied: answer 416.
class UnsatisfiableRange extends RangeResult {
  const UnsatisfiableRange();
}

final _single = RegExp(r'^(\d*)-(\d*)$');

RangeResult parseRange(String? header, int size) {
  if (header == null) return const FullRange();
  final h = header.trim();
  if (!h.toLowerCase().startsWith('bytes=')) return const FullRange();
  final spec = h.substring(6).trim();
  if (spec.contains(',')) return const FullRange(); // multi-range: ignored
  final m = _single.firstMatch(spec);
  if (m == null) return const FullRange();
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return const FullRange();
  final sizeBig = BigInt.from(size);
  if (a.isEmpty) {
    final n = BigInt.parse(b); // suffix: last n bytes
    if (n == BigInt.zero || size == 0) return const UnsatisfiableRange();
    if (n >= sizeBig) return SingleRange(0, size - 1);
    return SingleRange(size - n.toInt(), size - 1);
  }
  final startBig = BigInt.parse(a);
  if (startBig >= sizeBig) return const UnsatisfiableRange();
  final start = startBig.toInt();
  if (b.isEmpty) return SingleRange(start, size - 1);
  final endBig = BigInt.parse(b);
  if (endBig < startBig) return const FullRange(); // syntactically invalid: ignore
  final end = endBig >= sizeBig ? size - 1 : endBig.toInt();
  return SingleRange(start, end);
}
