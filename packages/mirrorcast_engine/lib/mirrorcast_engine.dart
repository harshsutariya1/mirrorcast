/// Dart API for the MirrorCast native engine.
///
/// * [SenderEngine] drives the Android side (pairing, capture, streaming).
/// * [ReceiverEngine] drives the macOS side (server, pairing, playback).
///
/// Both talk to native code over the `com.mirrorcast/control` method channel
/// and listen on `com.mirrorcast/events`. Only commands and small status
/// updates cross the bridge; video and audio stay native end to end.
library;

export 'src/channels.dart' show EngineException;
export 'src/pairing_link.dart';
export 'src/receiver_engine.dart';
export 'src/sender_engine.dart';
