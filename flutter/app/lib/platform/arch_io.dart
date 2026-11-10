import 'dart:ffi' show Abi;

String? currentArch() => switch (Abi.current()) {
      Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 || Abi.androidArm64 => 'arm64',
      Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 || Abi.androidX64 => 'x64',
      _ => null,
    };
