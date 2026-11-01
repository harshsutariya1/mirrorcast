# CocoaPods spec for the MirrorCast macOS engine. Flutter uses Swift Package
# Manager by default (see mirrorcast_engine/Package.swift); this file keeps
# CocoaPods-based builds working too.
Pod::Spec.new do |s|
  s.name             = 'mirrorcast_engine'
  s.version          = '1.0.0'
  s.summary          = 'MirrorCast native engine: TLS server, VideoToolbox decoder, low-latency audio.'
  s.description      = <<-DESC
The data plane of the MirrorCast receiver. Video and audio never pass through Dart.
                       DESC
  s.homepage         = 'https://github.com/harshsutariya1/mirrorcast'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'MirrorCast' => 'noreply@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'mirrorcast_engine/Sources/mirrorcast_engine/**/*.swift'
  s.resource_bundles = { 'mirrorcast_engine_privacy' => ['mirrorcast_engine/Sources/mirrorcast_engine/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Network', 'Security', 'SystemConfiguration', 'VideoToolbox'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.9'
end
