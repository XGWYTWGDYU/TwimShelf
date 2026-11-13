# One step from a fresh checkout to installable packages, on Windows 10 1803 or later.
#
#   powershell -ExecutionPolicy Bypass -File build.ps1                    windows + android
#   powershell -ExecutionPolicy Bypass -File build.ps1 flutter-windows
# Each build applies config.yaml first (names, ids, icons, share).
#   … -Check     only check the tools      … -Yes     install what is missing without asking
#
# Each missing tool is named with what installing it takes; nothing is installed without a yes.
# Installs use winget (part of Windows 10/11 App Installer). Where things go is build.dir in
# config.yaml: every cache (Rust, Flutter, Gradle, Dart packages, downloaded SDKs) in <dir>\cache,
# the setup and APKs in <dir>\apps.
#   FLUTTER_ROOT    an existing Flutter SDK; ANDROID_HOME an existing Android SDK
#   TL_UPDATE_REPO  owner/name: a GitHub build (检查更新); empty for local builds
#   TL_VERSION      the version in the packages' file names (default: version in config.yaml)
param([string[]]$Targets = @(), [switch]$Check, [switch]$Yes)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path "$PSScriptRoot").Path
# pinned: Flutter in .fvmrc, Rust in rust-toolchain.toml (rustup installs that one on first use)
$FlutterVersion = (Get-Content "$Root\.fvmrc" -Raw | ConvertFrom-Json).flutter
# Flutter builds for the machine it runs on: an ARM64 Windows makes the ARM64 app, x64 the x64 one
$Arm = $env:PROCESSOR_ARCHITECTURE -eq 'ARM64'
$Arch = if ($Arm) { 'arm64' } else { 'x64' }
$RustTarget = if ($Arm) { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$Missing = @()

function Say($m) { Write-Host $m -ForegroundColor Cyan }
function Fail($m) { Write-Host $m -ForegroundColor Red; exit 1 }
function Ask($q) { if ($Yes) { return $true }; if ($Check) { return $false }; (Read-Host "$q [y/N]") -match '^[yY]' }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
# PATH again from the registry (after an install), keeping what this script put in front
$ExtraPath = ''
function Refresh-Path { $env:Path = $script:ExtraPath + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\.cargo\bin" }

function Need-Winget($cmd, $what, $id, $extra = '') {
  if (Have $cmd) { return }
  Say "Missing: $what"
  if (-not (Have winget)) { Fail "winget (App Installer from the Microsoft Store) is needed to install $what" }
  if (Ask "Install $what with winget ($id)?") {
    winget install --id $id -e --accept-source-agreements --accept-package-agreements $extra.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
    Refresh-Path
  }
  if (-not (Have $cmd)) { if ($Check) { $script:Missing += $what } else { Fail "$what is required" } }
}

function Need-VisualStudio {
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $ok = (Test-Path $vswhere) -and (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if (-not $ok) {
    Say 'Missing: Visual Studio Build Tools with C++ (about 6 GB)'
    if (Ask 'Install Visual Studio 2022 Build Tools (C++ workload) with winget?') {
      winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements --override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    } elseif ($Check) { $script:Missing += 'Visual Studio Build Tools'; return } else { Fail 'The C++ build tools are required' }
  }

  $vsPath = & $vswhere -latest -products * -property installationPath
  # ATL (secure storage's Windows plugin uses it): not part of the C++ workload's defaults
  $atl = if ($Arm) { 'Microsoft.VisualStudio.Component.VC.ATL.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.ATL' }
  if (-not (& $vswhere -latest -products * -requires $atl -property installationPath)) {
    Say 'Missing: the C++ ATL of Visual Studio (about 50 MB)'
    if (Ask "Add it to Visual Studio (component $atl)?") {
      & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" modify --installPath "$vsPath" --add $atl --quiet --norestart --nocache | Out-Null
    }
    if (-not (& $vswhere -latest -products * -requires $atl -property installationPath)) { if ($Check) { $script:Missing += 'Visual Studio ATL' } else { Fail 'The C++ ATL is required' } }
  }

  # ARM64 Windows: the crypto library under TLS (ring) needs Visual Studio's own clang there
  if ($Arm) {
    $llvm = "$vsPath\VC\Tools\Llvm\ARM64\bin"
    if (-not (Test-Path "$llvm\clang.exe")) {
      Say 'Missing: the C++ Clang compiler of Visual Studio (needed on ARM64; about 1 GB)'
      if (Ask 'Add it to Visual Studio (component Microsoft.VisualStudio.Component.VC.Llvm.Clang)?') {
        & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" modify --installPath "$vsPath" --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --quiet --norestart --nocache | Out-Null
      }
      if (-not (Test-Path "$llvm\clang.exe")) { if ($Check) { $script:Missing += 'Visual Studio clang (ARM64)' } else { Fail 'The clang compiler is required on ARM64' } }
    }
    $script:ExtraPath = "$llvm;"
    $env:Path = "$llvm;$env:Path"
  }
}

function Need-Rust {
  Refresh-Path
  # a Rust without rustup (the standalone installer) is fine: it comes with its own target
  if ((Have rustup) -or ((Have cargo) -and -not $Check)) { return }
  Say 'Missing: Rust (about 300 MB)'
  if (Ask 'Install Rust (rustup) with winget?') { winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements; Refresh-Path }
  if (-not (Have rustup)) { if ($Check) { $script:Missing += 'Rust' } else { Fail 'Rust is required' } }
}

function Need-Flutter {
  if ($env:FLUTTER_ROOT -and (Test-Path "$env:FLUTTER_ROOT\bin\flutter.bat")) { $script:Flutter = "$env:FLUTTER_ROOT\bin\flutter.bat"; return }
  if (Have flutter) { $script:Flutter = (Get-Command flutter).Source; return }
  if (Test-Path "$Cache\sdk\flutter\bin\flutter.bat") { $script:Flutter = "$Cache\sdk\flutter\bin\flutter.bat"; return }
  Say "Missing: Flutter $FlutterVersion (about 1.5 GB)"
  Need-Winget git 'Git' 'Git.Git'
  if (Ask "Download Flutter $FlutterVersion into $Cache\sdk\flutter?") {
    git clone --depth 1 --branch $FlutterVersion https://github.com/flutter/flutter.git "$Cache\sdk\flutter"
    $script:Flutter = "$Cache\sdk\flutter\bin\flutter.bat"
  } elseif ($Check) { $script:Missing += 'Flutter' } else { Fail 'Flutter is required' }
}

function Need-Vulkan {
  if ($env:VULKAN_SDK) { return }
  Say 'Missing: Vulkan SDK (GPU support for on-device AI; about 500 MB). Without it the AI runs on the processor only.'
  if (Ask 'Install the Vulkan SDK with winget?') { winget install --id KhronosGroup.VulkanSDK -e --accept-source-agreements --accept-package-agreements; Refresh-Path }
}

function Need-Android {
  if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = "$Cache\sdk\android" }
  Need-Winget java 'Java 17 (for Gradle)' 'Microsoft.OpenJDK.17'
  $sdkm = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
  if (-not (Test-Path $sdkm)) {
    Say 'Missing: Android SDK command-line tools (about 150 MB, more for the SDK parts)'
    if (Ask "Download them into $env:ANDROID_HOME?") {
      $zip = "$Cache\sdk\cmdline-tools.zip"
      Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip' -OutFile $zip
      Expand-Archive $zip "$env:ANDROID_HOME\cmdline-tools" -Force
      Move-Item "$env:ANDROID_HOME\cmdline-tools\cmdline-tools" "$env:ANDROID_HOME\cmdline-tools\latest" -Force
    } elseif ($Check) { $script:Missing += 'Android SDK'; return } else { Fail 'The Android SDK is required' }
  }
  $ext = Get-Content "$(Split-Path (Split-Path $Flutter))\packages\flutter_tools\gradle\src\main\kotlin\FlutterExtension.kt" -Raw
  $ndk = [regex]::Match($ext, 'ndkVersion[^=]*= "([^"]+)"').Groups[1].Value
  $parts = @('platform-tools', 'platforms;android-36', 'build-tools;36.0.0', "ndk;$ndk", 'cmake;3.31.6') | Where-Object { -not (Test-Path ("$env:ANDROID_HOME\" + ($_ -replace ';', '\'))) }
  if ($parts) {
    Say "Missing Android SDK parts: $($parts -join ', ') (the NDK is about 1 GB)"
    if (Ask 'Install them with sdkmanager?') { 'y' * 20 | & $sdkm --sdk_root="$env:ANDROID_HOME" --licenses | Out-Null; & $sdkm --sdk_root="$env:ANDROID_HOME" @parts }
    elseif ($Check) { $script:Missing += 'Android SDK parts' } else { Fail 'The Android SDK parts are required' }
  }
  $env:ANDROID_NDK_HOME = "$env:ANDROID_HOME\ndk\$ndk"
}

function Version { if ($env:TL_VERSION) { $env:TL_VERSION } else { (python "$Root\scripts\apply.py" get version).Trim() } }
function Defines {
  "--dart-define=TL_SHARE=$(python "$Root\scripts\apply.py" get flutter.share_extension)"
  if ($env:TL_UPDATE_REPO) { "--dart-define=TL_UPDATE_REPO=$env:TL_UPDATE_REPO" }
}

function Build-Core-Windows {
  if (Have rustup) { rustup target add $RustTarget | Out-Null }
  # HEIC and AVIF (core\build.rs): the CMake that comes with the C++ tools
  $env:CMAKE = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' | Select-Object -First 1
  $env:CARGO_TARGET_DIR = "$Cache\cargo"
  Push-Location "$Root\core"
  cargo rustc --locked --lib --release --features heif --target $RustTarget --crate-type cdylib
  $failed = $LASTEXITCODE; Pop-Location
  if ($failed) { Fail 'Building the Rust core failed' }
  # tl_core\windows\lib is a link into <dir>\cache (scripts\apply.py)
  Copy-Item "$Cache\cargo\$RustTarget\release\tl_core.dll", "$Cache\cargo\$RustTarget\release\tl_core.dll.lib" "$Root\flutter\tl_core\windows\lib\" -Force
}

function Build-Windows {
  Need-VisualStudio; Need-Rust; Need-Flutter; Need-Vulkan
  $v = Version
  Build-Core-Windows
  Push-Location "$Root\flutter\app"; & $Flutter pub get; & $Flutter build windows --release (Defines); $failed = $LASTEXITCODE; Pop-Location
  if ($failed) { Fail 'Building the app failed' }
  Push-Location "$Root\flutter\installer"; & $Flutter pub get; & $Flutter build windows --release; $failed = $LASTEXITCODE; Pop-Location
  if ($failed) { Fail 'Building the setup app failed' }
  # the setup: stub + tar(setup app, program, payload.json) + length + marker
  $stage = "$Cache\setup\stage"
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force "$stage\setup", "$stage\payload" | Out-Null
  Copy-Item "$Root\flutter\installer\build\windows\$Arch\runner\Release\*" "$stage\setup" -Recurse
  Copy-Item "$Root\flutter\app\build\windows\$Arch\runner\Release\*" "$stage\payload" -Recurse
  # the Visual C++ runtime goes into the program's own folder (no separate redistributable)
  $vsdir = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
  $crt = Get-ChildItem "$vsdir\VC\Redist\MSVC\*\$Arch\Microsoft.VC14*.CRT" -Directory | Select-Object -Last 1
  if ($crt) { Copy-Item "$($crt.FullName)\*.dll" "$stage\payload"; Copy-Item "$($crt.FullName)\*.dll" "$stage\setup" }
  $product = Get-Content "$Root\flutter\installer\product.json" -Raw | ConvertFrom-Json
  $product.version = $v
  $product | ConvertTo-Json | Set-Content "$stage\payload.json" -Encoding utf8
  Push-Location $stage; & "$env:SystemRoot\System32\tar.exe" -cf "$Cache\setup\payload.tar" setup payload payload.json; Pop-Location
  # the stub, with the Visual Studio compiler
  $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
  $obj = "$Cache\setup\stub"; New-Item -ItemType Directory -Force $obj | Out-Null
  # the setup file's own icon: from the app's AppIcon set, as everything else
  python "$Root\scripts\flutter\desktop_assets.py" $obj
  if ($LASTEXITCODE) { Fail 'Making the setup icon failed' }
  $vcvars = if ($Arm) { 'vcvarsarm64.bat' } else { 'vcvars64.bat' }
  cmd /c "`"$vs\VC\Auxiliary\Build\$vcvars`" && cd /d `"$Root\flutter\installer\stub`" && rc /nologo /i `"$obj`" /fo `"$obj\setup_stub.res`" setup_stub.rc && cl /nologo /std:c++17 /O2 /EHsc /DUNICODE /D_UNICODE /Fo`"$obj\\`" /Fe`"$obj\setup_stub.exe`" setup_stub.cpp `"$obj\setup_stub.res`" /link /SUBSYSTEM:WINDOWS shell32.lib user32.lib"
  if ($LASTEXITCODE) { Fail 'Building the setup stub failed' }
  $name = "$($product.file)-Flutter-$v-windows-$Arch-setup.exe"
  $out = [IO.File]::Create("$Dist\$name")
  foreach ($part in "$obj\setup_stub.exe", "$Cache\setup\payload.tar") { $in = [IO.File]::OpenRead($part); $in.CopyTo($out); $in.Close() }
  $len = (Get-Item "$Cache\setup\payload.tar").Length
  $out.Write([BitConverter]::GetBytes([UInt64]$len), 0, 8)
  $out.Write([Text.Encoding]::ASCII.GetBytes('TLSETUP1'), 0, 8)
  $out.Close()
  Say "Built $Dist\$name"
}

function Build-Android {
  Need-Rust; Need-Flutter; Need-Android
  $v = Version
  if (-not (Have cargo-ndk)) { if (Ask 'Install cargo-ndk (cargo install cargo-ndk)?') { cargo install cargo-ndk } }
  $env:CARGO_TARGET_DIR = "$Cache\cargo"
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android | Out-Null
  $env:CMAKE = "$env:ANDROID_HOME\cmake\3.31.6\bin\cmake.exe"
  Push-Location "$Root\core"; cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 31 -o "$Root\flutter\tl_core\android\src\main\jniLibs" rustc --locked --lib --release --features heif --crate-type cdylib; Pop-Location
  Push-Location "$Root\flutter\app"; & $Flutter pub get; & $Flutter build apk --release --split-per-abi (Defines); Pop-Location
  Get-ChildItem "$Root\flutter\app\build\app\outputs\flutter-apk\app-*-release.apk" | ForEach-Object {
    $abi = $_.Name -replace 'app-(.*)-release.apk', '$1'
    Copy-Item $_.FullName "$Dist\TwimShelf-Flutter-$v-android-$abi.apk"
  }
  Say 'Built flutter-android'
}

if (-not $Targets) { $Targets = @('flutter-windows', 'flutter-android') }
# config.yaml first: the names, ids and icons, and where builds go
Need-Winget python 'Python 3' 'Python.Python.3.12'
python "$Root\scripts\apply.py" flutter
$Cache = (python "$Root\scripts\apply.py" where cache).Trim()
$Dist = (python "$Root\scripts\apply.py" where apps).Trim()
New-Item -ItemType Directory -Force -Path "$Cache\sdk", "$Cache\setup", $Dist | Out-Null
$env:PUB_CACHE = "$Cache\pub"; $env:GRADLE_USER_HOME = "$Cache\gradle"
if ($Check) {
  foreach ($t in $Targets) {
    switch ($t) { 'flutter-windows' { Need-VisualStudio; Need-Rust; Need-Flutter; Need-Vulkan } 'flutter-android' { Need-Rust; Need-Flutter; Need-Android } }
  }
  if ($Missing) { Say "Missing: $($Missing -join ', ')"; exit 1 }
  Say "Everything needed for $($Targets -join ', ') is here"; exit 0
}
foreach ($t in $Targets) {
  switch ($t) {
    'flutter-windows' { Build-Windows }
    'flutter-android' { Build-Android }
    default { Fail "$t builds on macOS or Linux: build.sh" }
  }
}
Say "Packages: $Dist"
Get-ChildItem $Dist | Select-Object -ExpandProperty Name
