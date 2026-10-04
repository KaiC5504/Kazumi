import 'dart:convert';

enum SkipSource { fingerprint, aniskip }

enum SkipKind { opening, ending }

class SkipRange {
  const SkipRange(this.start, this.end, this.source);

  /// Seconds from the start of the episode.
  final double start;
  final double end;
  final SkipSource source;

  double get length => end - start;

  bool contains(double seconds) => seconds >= start && seconds < end;

  factory SkipRange.fromJson(Map<String, dynamic> json) => SkipRange(
    (json['start'] as num).toDouble(),
    (json['end'] as num).toDouble(),
    SkipSource.values.asNameMap()[json['source']] ?? SkipSource.aniskip,
  );

  Map<String, dynamic> toJson() => {
    'start': double.parse(start.toStringAsFixed(2)),
    'end': double.parse(end.toStringAsFixed(2)),
    'source': source.name,
  };

  @override
  bool operator ==(Object other) =>
      other is SkipRange &&
      (other.start - start).abs() < 0.05 &&
      (other.end - end).abs() < 0.05 &&
      other.source == source;

  @override
  int get hashCode => Object.hash(start.round(), end.round(), source);

  @override
  String toString() =>
      '${start.toStringAsFixed(1)}-${end.toStringAsFixed(1)}s (${source.name})';
}

/// Where an episode's opening and ending are, as detected on the PC.
class SkipSegments {
  const SkipSegments({this.opening, this.ending});

  final SkipRange? opening;
  final SkipRange? ending;

  static const empty = SkipSegments();

  bool get isEmpty => opening == null && ending == null;

  SkipRange? operator [](SkipKind kind) =>
      kind == SkipKind.opening ? opening : ending;

  /// The segment playing at [seconds], if any.
  (SkipKind, SkipRange)? activeAt(double seconds) {
    if (opening?.contains(seconds) ?? false) {
      return (SkipKind.opening, opening!);
    }
    if (ending?.contains(seconds) ?? false) return (SkipKind.ending, ending!);
    return null;
  }

  factory SkipSegments.fromJson(Map<String, dynamic> json) => SkipSegments(
    opening: json['op'] is Map
        ? SkipRange.fromJson((json['op'] as Map).cast<String, dynamic>())
        : null,
    ending: json['ed'] is Map
        ? SkipRange.fromJson((json['ed'] as Map).cast<String, dynamic>())
        : null,
  );

  Map<String, dynamic> toJson() => {
    if (opening != null) 'op': opening!.toJson(),
    if (ending != null) 'ed': ending!.toJson(),
  };

  /// Empty string when there is nothing to store.
  String encode() => isEmpty ? '' : jsonEncode(toJson());

  static SkipSegments decode(String source) {
    if (source.isEmpty) return empty;
    try {
      return SkipSegments.fromJson(jsonDecode(source) as Map<String, dynamic>);
    } on Object {
      return empty;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SkipSegments &&
      other.opening == opening &&
      other.ending == ending;

  @override
  int get hashCode => Object.hash(opening, ending);

  @override
  String toString() => 'SkipSegments(op: $opening, ed: $ending)';
}
