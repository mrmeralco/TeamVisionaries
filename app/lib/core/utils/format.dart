// Contract conventions (C-api.md): timestamps are Unix seconds UTC, days are Asia/Manila (UTC+8, no DST),
// money is pesos, energy kWh, power W.
import 'package:intl/intl.dart';

const _manilaOffset = Duration(hours: 8);

/// Unix seconds → wall-clock time in Manila. Returned as a UTC DateTime shifted by +8 h,
/// so format it directly (don't call toLocal()).
DateTime manilaTime(int ts) =>
    DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).add(_manilaOffset);

final _php = NumberFormat.currency(locale: 'en_PH', symbol: '₱', decimalDigits: 2);
final _phpWhole = NumberFormat.currency(locale: 'en_PH', symbol: '₱', decimalDigits: 0);

/// ₱1,290.00, or ₱1,290 with [whole].
String formatPhp(num value, {bool whole = false}) => (whole ? _phpWhole : _php).format(value);

/// 1800 → "1.8 kW", 900 → "900 W".
String formatWatts(num w) => w.abs() >= 1000 ? '${(w / 1000).toStringAsFixed(1)} kW' : '${w.round()} W';

String formatKwh(num kwh) => '${kwh.toStringAsFixed(kwh >= 10 ? 1 : 2)} kWh';

/// "3:05 PM" in Manila time.
String formatClock(int ts) => DateFormat('h:mm a').format(manilaTime(ts));

/// "Nov 12, 3:05 PM" in Manila time.
String formatDateTime(int ts) => DateFormat('MMM d, h:mm a').format(manilaTime(ts));

// ---- Number-only variants for the designed tiles (value and unit are drawn separately) ----

/// Watts → "3.2" (kW, one decimal).
String kwNum(Object? watts) => ((watts is num ? watts : 0).abs() / 1000).toStringAsFixed(1);

/// kWh → "18.4", or two decimals under 10 so small days still read ("5.67").
String kwhNum(Object? v) {
  final x = (v is num ? v : 0).toDouble();
  return x.abs() < 10 ? x.toStringAsFixed(2) : x.toStringAsFixed(1);
}

/// 64 → "64", 83.7 → "83.7".
String pctNum(Object? v) {
  final x = v is num ? v : 0;
  return x.toStringAsFixed(x % 1 == 0 ? 0 : 1);
}

/// Current wall-clock time in Manila (same convention as [manilaTime]).
DateTime manilaNow() => DateTime.now().toUtc().add(_manilaOffset);

/// "Nov 2" in Manila time.
String formatShortDate(int ts) => DateFormat('MMM d').format(manilaTime(ts));

/// "NOVEMBER" for "2026-11".
String monthNameOf(String yyyyMm) {
  final m = int.tryParse(yyyyMm.split('-').last) ?? 1;
  return DateFormat('MMMM').format(DateTime.utc(2000, m.clamp(1, 12)));
}

/// "Just now", "5 min ago", "3 hr ago", then the date.
String formatAgo(int ts, {DateTime? now}) {
  final s = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 - ts;
  if (s < 60) return 'Just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} hr ago';
  return formatShortDate(ts);
}

/// Same Manila calendar day as [now].
bool isTodayManila(int ts, {DateTime? now}) {
  final d = manilaTime(ts);
  final n = (now ?? DateTime.now()).toUtc().add(_manilaOffset);
  return d.year == n.year && d.month == n.month && d.day == n.day;
}
