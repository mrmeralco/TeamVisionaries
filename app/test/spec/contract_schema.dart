// Tiny JSON-Schema checker for docs/contracts/schema.json (the subset that file uses).
// Lets the Flutter tests use the SAME contract the backend tests use.
import 'dart:convert';
import 'dart:io';

/// Folder with schema.json and examples/. Tests run from app/, so the default is ../docs/contracts.
final contractsDir = Platform.environment['SINAG_CONTRACTS'] ?? '../docs/contracts';

final Map<String, dynamic> _schema =
    jsonDecode(File('$contractsDir/schema.json').readAsStringSync()) as Map<String, dynamic>;
Map<String, dynamic> get _defs => _schema[r'$defs'] as Map<String, dynamic>;

Map<String, dynamic> example(String name) =>
    jsonDecode(File('$contractsDir/examples/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// Returns a list of problems ("telemetry/pv_w: expected integer, got String"). Empty = valid.
List<String> contractErrors(String name, Object? value) {
  if (!_defs.containsKey(name)) throw ArgumentError('no contract named $name');
  final errs = <String>[];
  _check(_defs[name] as Map<String, dynamic>, value, name, errs);
  return errs;
}

void _check(Map<String, dynamic> s, Object? v, String path, List<String> errs) {
  if (s.containsKey(r'$ref')) {
    final ref = (s[r'$ref'] as String).split('/').last;
    _check(_defs[ref] as Map<String, dynamic>, v, path, errs);
  }
  if (s.containsKey('allOf')) {
    for (final sub in s['allOf'] as List) {
      _check(sub as Map<String, dynamic>, v, path, errs);
    }
  }
  if (s.containsKey('oneOf')) {
    final ok = (s['oneOf'] as List).where((sub) {
      final e = <String>[];
      _check(sub as Map<String, dynamic>, v, path, e);
      return e.isEmpty;
    }).length;
    if (ok != 1) errs.add('$path: matches $ok of the allowed shapes (need exactly 1)');
    return;
  }
  if (s.containsKey('const') && v != s['const']) errs.add('$path: must be ${s['const']}, got $v');
  if (s.containsKey('enum') && !(s['enum'] as List).contains(v)) errs.add('$path: $v is not one of ${s['enum']}');
  if (s.containsKey('type')) {
    final types = s['type'] is List ? (s['type'] as List).cast<String>() : [s['type'] as String];
    if (!types.any((t) => _isType(t, v))) {
      errs.add('$path: expected ${types.join('|')}, got ${v.runtimeType} ($v)');
      return;
    }
  }
  if (v is num) {
    if (s['minimum'] is num && v < (s['minimum'] as num)) errs.add('$path: $v < minimum ${s['minimum']}');
    if (s['maximum'] is num && v > (s['maximum'] as num)) errs.add('$path: $v > maximum ${s['maximum']}');
  }
  if (v is String && s['minLength'] is int && v.length < (s['minLength'] as int)) errs.add('$path: empty string');
  if (v is Map) {
    for (final r in (s['required'] as List? ?? const [])) {
      if (!v.containsKey(r)) errs.add('$path: missing "$r"');
    }
    final props = s['properties'] as Map<String, dynamic>? ?? const {};
    props.forEach((k, sub) {
      if (v.containsKey(k)) _check(sub as Map<String, dynamic>, v[k], '$path/$k', errs);
    });
  }
  if (v is List) {
    if (s['minItems'] is int && v.length < (s['minItems'] as int)) errs.add('$path: fewer than ${s['minItems']} items');
    if (s['items'] is Map) {
      for (var i = 0; i < v.length; i++) {
        _check(s['items'] as Map<String, dynamic>, v[i], '$path[$i]', errs);
      }
    }
  }
}

bool _isType(String t, Object? v) => switch (t) {
      'object' => v is Map,
      'array' => v is List,
      'string' => v is String,
      'integer' => v is int,
      'number' => v is num,
      'boolean' => v is bool,
      'null' => v == null,
      _ => true,
    };

/// Accepts a Map or any model with toJson(), so you can return your own model classes.
Object? asJson(Object? x) {
  if (x == null || x is Map || x is List || x is num || x is String || x is bool) return x;
  try {
    return jsonDecode(jsonEncode((x as dynamic).toJson()));
  } on NoSuchMethodError {
    throw StateError('${x.runtimeType} has no toJson(): add one that returns the contract shape');
  }
}
