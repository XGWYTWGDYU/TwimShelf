import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../tl_core.dart' show openCoreLibrary;
import 'bindings.dart';

/// The mascot's little Clawd, shared with the native apps (core/src/pet.rs): what it does and how
/// it looks; a front end paints the rectangles and passes on the pointer and the taps.
///
/// Not thread-safe; call [dispose] when it goes away.
class PetEngine {
  PetEngine(int seed) : _handle = _b.tl_pet_new(seed);

  static final CoreBindings _b = CoreBindings(openCoreLibrary());
  static const _capacity = 400;
  final Pointer<TlPet> _handle;
  final Pointer<Double> _buffer = malloc<Double>(5 * _capacity);
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.tl_pet_free(_handle);
    malloc.free(_buffer);
  }

  void setBounds(double width, double height, double marginRight, double marginBottom) =>
      _b.tl_pet_set_bounds(_handle, width, height, marginRight, marginBottom);
  void pointer(double x, double y) => _b.tl_pet_pointer(_handle, x, y);
  void pointerGone() => _b.tl_pet_pointer_gone(_handle);
  bool hit(double x, double y) => _b.tl_pet_hit(_handle, x, y);
  bool tap(double x, double y) => _b.tl_pet_tap(_handle, x, y);

  /// Advances and returns the picture: x, y, w, h, ARGB per rectangle, back to front.
  List<double> tick(double seconds) {
    final n = _b.tl_pet_tick(_handle, seconds, _buffer, _capacity);
    final count = n > _capacity ? _capacity : n;
    return List<double>.of(_buffer.asTypedList(count * 5));
  }
}
