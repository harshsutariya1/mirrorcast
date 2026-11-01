# MirrorCast release shrinking rules.
# The engine is reached by Flutter's plugin registrant and by Android (the
# foreground service), so keep it intact.
-keep class com.mirrorcast.engine.** { *; }
