Pod::Spec.new do |s|
  s.name = 'tl_core'
  s.version = '0.1.0'
  s.summary = 'Local Rust core packaging for TwimShelf.'
  s.description = s.summary
  s.homepage = 'https://localhost'
  s.license = { :type => 'Private' }
  s.author = 'TwimShelf'
  s.source = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.vendored_frameworks = 'TlCore.xcframework'
  s.static_framework = true
  # FFI resolves static Rust exports through DynamicLibrary.process().
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64', 'OTHER_LDFLAGS' => '$(inherited) -Wl,-all_load -lc++' }
  s.user_target_xcconfig = { 'OTHER_LDFLAGS' => '$(inherited) -Wl,-all_load -lc++', 'DEAD_CODE_STRIPPING' => 'NO', 'ENABLE_DEBUG_DYLIB' => 'NO', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64' }
end
