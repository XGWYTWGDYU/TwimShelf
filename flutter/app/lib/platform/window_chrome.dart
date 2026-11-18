import 'package:flutter/widgets.dart';

import 'apple_platform.dart';

/// Where a windowed iPad's own controls sit (its window buttons over the app's top-leading
/// corner), so pages keep clear of them. Empty everywhere else.
class WindowChrome {
  static Rect leading(BuildContext context) => ApplePlatform.instance.windowControls.value;

  /// The height everything that touches the top edge leaves free.
  static double top(BuildContext context) => leading(context).bottom;
}
