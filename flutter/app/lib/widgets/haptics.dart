import 'package:flutter/services.dart';

/// A switch's onChanged that ticks before it acts, like a native switch flipping.
ValueChanged<bool>? withHaptic(ValueChanged<bool>? changed) => changed == null
    ? null
    : (v) {
        HapticFeedback.selectionClick();
        changed(v);
      };
