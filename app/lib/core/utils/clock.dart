// The app's clock (Manila time) and when it is night. Home reads it for the greeting and the night
// house; the app reads it to go dark at night. Tests set [homeClock].
import 'package:flutter/foundation.dart';

import 'format.dart';

@visibleForTesting
DateTime Function() homeClock = manilaNow;

/// Night in the Philippines: 6 PM to 6 AM, Manila time.
bool isNightAt(DateTime manila) => manila.hour >= 18 || manila.hour < 6;
