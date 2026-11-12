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
