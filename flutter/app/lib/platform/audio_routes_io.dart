import 'dart:async';

import 'package:audio_session/audio_session.dart' as audio;

abstract interface class HeadphoneRoutes {
  Future<bool> current();
  Stream<bool> get changes;
  Future<void> dispose();
}

/// Unknown routes are treated as speakers, never as permission to play sound.
class SystemHeadphoneRoutes implements HeadphoneRoutes {
  SystemHeadphoneRoutes() {
    _changes = StreamController<bool>.broadcast(
      onListen: _watch,
      onCancel: _stop,
    );
  }
  late final StreamController<bool> _changes;
  StreamSubscription<dynamic>? _devices, _noisy;
  bool? _last;
  bool _closed = false, _sampling = false, _resample = false;
  int _routeEpoch = 0;
  @override
  Stream<bool> get changes => _changes.stream;
  @override
  Future<bool> current() async {
    try {
      final session = await audio.AudioSession.instance;
      final devices = await session.getDevices(includeInputs: false);
      return devices.any(
        (d) =>
            d.isOutput &&
            (d.type.name.startsWith('bluetooth') ||
                const {
                  'wiredHeadset',
                  'wiredHeadphones',
                  'usbAudio',
                  'usbHeadset',
                }.contains(d.type.name)),
      );
    } catch (_) {
      return false;
    }
  }

  void _emit(bool value) {
    if (!_closed && value != _last) {
      _last = value;
      _changes.add(value);
    }
  }

  Future<void> _sample() async {
    if (_closed) return;
    if (_sampling) {
      _resample = true;
      return;
    }
    _sampling = true;
    final epoch = _routeEpoch;
    try {
      final value = await current();
      if (epoch == _routeEpoch) _emit(value);
    } finally {
      _sampling = false;
      if (_resample && !_closed) {
        _resample = false;
        unawaited(_sample());
      }
    }
  }

  void _watch() {
    if (_closed) return;
    unawaited(_sample());
    unawaited(
      () async {
        final session = await audio.AudioSession.instance;
        if (_closed || !_changes.hasListener) return;
        _devices = session.devicesChangedEventStream.listen((_) {
          _routeEpoch++;
          unawaited(_sample());
        });
        _noisy = session.becomingNoisyEventStream.listen((_) {
          _routeEpoch++;
          _emit(false);
        });
      }().catchError((Object _) {
        _emit(false);
      }),
    );
  }

  void _stop() {
    unawaited(_devices?.cancel());
    unawaited(_noisy?.cancel());
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _stop();
    await _changes.close();
  }
}
