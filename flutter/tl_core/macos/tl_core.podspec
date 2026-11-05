Pod::Spec.new do |s|
  s.name = 'tl_core'
  s.version = '0.1.0'
  s.summary = 'Local Rust core packaging for TwimShelf.'
  s.description = s.summary
  s.homepage = 'https://localhost'
  s.license = { :type => 'Private' }
  s.author = 'TwimShelf'
  s.source = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.vendored_frameworks = 'TlCore.xcframework'
  s.static_framework = true
  # FFI resolves static Rust exports through DynamicLibrary.process().
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'OTHER_LDFLAGS' => '$(inherited) -Wl,-all_load -lc++' }
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-all_load -lc++', 'DEAD_CODE_STRIPPING' => 'NO', 'ENABLE_DEBUG_DYLIB' => 'NO' }
end
