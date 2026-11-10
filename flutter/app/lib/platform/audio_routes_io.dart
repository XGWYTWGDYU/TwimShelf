import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:audio_session/audio_session.dart' as audio;
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as windows;
import 'os.dart';

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
  Timer? _timer;
  StreamSubscription<dynamic>? _devices, _noisy;
  bool? _last;
  bool _closed = false, _sampling = false, _resample = false;
  int _routeEpoch = 0;
  @override
  Stream<bool> get changes => _changes.stream;
  @override
  Future<bool> current() async {
    try {
      if (OS.isMacOS) return _macHeadphones();
      if (OS.isWindows) return _windowsHeadphones();
      if (OS.isLinux) {
        final selected = await _pactl(['get-default-sink']);
        final devices = await _pactl(['--format=json', 'list', 'sinks']);
        if (selected == null || devices == null) return false;
        final name = selected.trim();
        for (final sink in jsonDecode(devices) as List) {
          if ((sink as Map)['name'] == name) {
            return isPrivateLinuxOutput(Map<String, dynamic>.from(sink));
          }
        }
        return false;
      }
      if (OS.isAndroid || OS.isIOS) {
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
      }
    } catch (_) {
      return false;
    }
    return false;
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
    if (OS.isAndroid || OS.isIOS) {
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
    } else {
      _timer = Timer.periodic(
        OS.isLinux
            ? const Duration(seconds: 1)
            : const Duration(milliseconds: 250),
        (_) => unawaited(_sample()),
      );
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
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

bool isPrivateLinuxOutput(Map<String, dynamic> sink) {
  final port = sink['active_port'];
  final name = port is Map ? port['name'] : port;
  final props = sink['properties'] as Map? ?? const {};
  return (name is String && name.toLowerCase().contains('headphone')) ||
      const {'usb', 'bluetooth'}.contains(props['device.bus']);
}

final class _AudioAddress extends Struct {
  @Uint32()
  external int selector;
  @Uint32()
  external int scope;
  @Uint32()
  external int element;
}

typedef _GetAudioDataNative = Int32 Function(
  Uint32,
  Pointer<_AudioAddress>,
  Uint32,
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _GetAudioData = int Function(
  int,
  Pointer<_AudioAddress>,
  int,
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Void>,
);

final class _MacAudio {
  static final get =
      DynamicLibrary.open(
        '/System/Library/Frameworks/CoreAudio.framework/CoreAudio',
      ).lookupFunction<_GetAudioDataNative, _GetAudioData>(
        'AudioObjectGetPropertyData',
      );
}

bool _macHeadphones() => using((arena) {
  final address = arena<_AudioAddress>(),
      size = arena<Uint32>(),
      value = arena<Uint32>();
  int? read(int object, int selector, {int scope = 0x676c6f62}) {
    address.ref
      ..selector = selector
      ..scope = scope
      ..element = 0;
    size.value = 4;
    return _MacAudio.get(object, address, 0, nullptr, size, value.cast()) == 0
        ? value.value
        : null;
  }

  final device = read(1, 0x644f7574); // default output ('dOut')
  if (device == null || device == 0) return false;
  final transport = read(device, 0x7472616e); // 'tran'
  if (const {0x626c7565, 0x626c6561, 0x75736220}.contains(transport)) {
    return true;
  }
  return read(device, 0x73737263, scope: 0x6f757470) ==
      0x6864706e; // output data source 'hdpn'
});

bool _windowsHeadphones() {
  final initialized = windows.CoInitializeEx(windows.COINIT_MULTITHREADED);
  windows.IMMDeviceEnumerator? enumerator;
  windows.IMMDevice? device;
  windows.IPropertyStore? properties;
  try {
    enumerator = windows.createInstance<windows.IMMDeviceEnumerator>(
      windows.MMDeviceEnumerator,
    );
    device = enumerator.getDefaultAudioEndpoint(
      windows.eRender,
      windows.eMultimedia,
    );
    properties = device?.openPropertyStore(windows.STGM_READ);
    if (properties == null) return false;
    return using((arena) {
      final key = arena<windows.PROPERTYKEY>();
      key.ref
        ..fmtid = windows.GUID('{1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E}')
        ..pid = 0;
      final value = windows.PropVariant<int>.fromPointer(
        properties!.getValue(key),
      );
      try {
        return const {3, 5}.contains(value.value);
      } // Headphones / Headset
      finally {
        value.free();
      }
    });
  } finally {
    properties?.release();
    device?.release();
    enumerator?.release();
    if (!initialized.isError) windows.CoUninitialize();
  }
}

Future<String?> _pactl(List<String> arguments) async {
  Process? process;
  try {
    process = await Process.start('pactl', arguments);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .catchError((Object _) => '');
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    final code = await process.exitCode.timeout(const Duration(seconds: 2));
    return code == 0 ? await output : null;
  } catch (_) {
    process?.kill();
    return null;
  }
}
