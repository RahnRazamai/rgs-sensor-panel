import 'dart:io';

import 'package:flutter/services.dart';

enum RgsMediaSessionState {
  active,
  loading,
  noSession,
  unavailable,
}

enum RgsMediaPlaybackState {
  playing,
  paused,
  stopped,
  unknown,
}

final class RgsMediaSnapshot {
  const RgsMediaSnapshot({
    required this.sessionState,
    required this.status,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.source = '',
    this.playbackState = RgsMediaPlaybackState.unknown,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.canPrevious = false,
    this.canTogglePlayPause = false,
    this.canNext = false,
  });

  const RgsMediaSnapshot.noSession([this.status = 'Nothing is playing.'])
      : sessionState = RgsMediaSessionState.noSession,
        title = '',
        artist = '',
        album = '',
        source = '',
        playbackState = RgsMediaPlaybackState.unknown,
        position = Duration.zero,
        duration = Duration.zero,
        canPrevious = false,
        canTogglePlayPause = false,
        canNext = false;

  const RgsMediaSnapshot.loading([
    this.status = 'Looking for an active Windows media session...',
  ])  : sessionState = RgsMediaSessionState.loading,
        title = '',
        artist = '',
        album = '',
        source = '',
        playbackState = RgsMediaPlaybackState.unknown,
        position = Duration.zero,
        duration = Duration.zero,
        canPrevious = false,
        canTogglePlayPause = false,
        canNext = false;

  const RgsMediaSnapshot.unavailable(this.status)
      : sessionState = RgsMediaSessionState.unavailable,
        title = '',
        artist = '',
        album = '',
        source = '',
        playbackState = RgsMediaPlaybackState.unknown,
        position = Duration.zero,
        duration = Duration.zero,
        canPrevious = false,
        canTogglePlayPause = false,
        canNext = false;

  final RgsMediaSessionState sessionState;
  final String status;
  final String title;
  final String artist;
  final String album;
  final String source;
  final RgsMediaPlaybackState playbackState;
  final Duration position;
  final Duration duration;
  final bool canPrevious;
  final bool canTogglePlayPause;
  final bool canNext;

  bool get hasSession => sessionState == RgsMediaSessionState.active;

  bool get isPlaying => playbackState == RgsMediaPlaybackState.playing;

  double? get progress {
    if (duration <= Duration.zero) {
      return null;
    }

    return position.inMilliseconds / duration.inMilliseconds;
  }

  factory RgsMediaSnapshot.fromChannelValue(Object? value) {
    if (value is! Map) {
      return const RgsMediaSnapshot.unavailable(
        'Windows returned an invalid media response.',
      );
    }

    final availableValue = value['available'];
    if (availableValue is! bool) {
      return const RgsMediaSnapshot.unavailable(
        'Windows returned an invalid media response.',
      );
    }

    final available = availableValue;
    final status = _asString(value['status']);
    if (!available) {
      return RgsMediaSnapshot.noSession(
        status.isEmpty ? 'Nothing is playing.' : status,
      );
    }

    final durationMs = _asNonNegativeInt(value['durationMs']);
    final rawPositionMs = _asNonNegativeInt(value['positionMs']);
    final positionMs =
        durationMs > 0 ? rawPositionMs.clamp(0, durationMs) : rawPositionMs;

    return RgsMediaSnapshot(
      sessionState: RgsMediaSessionState.active,
      status: status.isEmpty ? 'Media session ready.' : status,
      title: _asString(value['title']),
      artist: _asString(value['artist']),
      album: _asString(value['album']),
      source: _asString(value['source']),
      playbackState: _playbackState(value['playbackState']),
      position: Duration(milliseconds: positionMs),
      duration: Duration(milliseconds: durationMs),
      canPrevious: _asBool(value['canPrevious']),
      canTogglePlayPause: _asBool(value['canTogglePlayPause']),
      canNext: _asBool(value['canNext']),
    );
  }

  static RgsMediaPlaybackState _playbackState(Object? value) {
    return switch (_asString(value).toLowerCase()) {
      'playing' => RgsMediaPlaybackState.playing,
      'paused' => RgsMediaPlaybackState.paused,
      'stopped' => RgsMediaPlaybackState.stopped,
      _ => RgsMediaPlaybackState.unknown,
    };
  }

  static String _asString(Object? value) => value?.toString().trim() ?? '';

  static bool _asBool(Object? value) => value is bool && value;

  static int _asNonNegativeInt(Object? value) {
    final number = switch (value) {
      int number => number,
      num number => number.round(),
      String text => int.tryParse(text) ?? 0,
      _ => 0,
    };
    return number < 0 ? 0 : number;
  }
}

abstract interface class RgsMediaController {
  Future<RgsMediaSnapshot> readSnapshot();

  Future<bool> previous();

  Future<bool> togglePlayPause();

  Future<bool> next();
}

final class RgsWindowsMediaController implements RgsMediaController {
  RgsWindowsMediaController({
    MethodChannel channel = const MethodChannel(_channelName),
    bool? isWindows,
  })  : _channel = channel,
        _isWindows = isWindows ?? Platform.isWindows;

  static final RgsWindowsMediaController instance = RgsWindowsMediaController();

  static const _channelName = 'studio.rahngaming.rgs_sensor_panel/media';

  final MethodChannel _channel;
  final bool _isWindows;

  @override
  Future<RgsMediaSnapshot> readSnapshot() async {
    if (!_isWindows) {
      return const RgsMediaSnapshot.unavailable(
        'Media controls are only available on Windows.',
      );
    }

    try {
      final value = await _channel.invokeMethod<Object?>('getSession');
      return RgsMediaSnapshot.fromChannelValue(value);
    } on PlatformException catch (error) {
      return RgsMediaSnapshot.unavailable(
        error.message ?? 'Windows media controls are unavailable.',
      );
    } on MissingPluginException {
      return const RgsMediaSnapshot.unavailable(
        'Windows media controls are unavailable in this build.',
      );
    } on Object {
      return const RgsMediaSnapshot.unavailable(
        'Windows could not read the active media session.',
      );
    }
  }

  @override
  Future<bool> previous() => _invokeCommand('previous');

  @override
  Future<bool> togglePlayPause() => _invokeCommand('togglePlayPause');

  @override
  Future<bool> next() => _invokeCommand('next');

  Future<bool> _invokeCommand(String method) async {
    if (!_isWindows) {
      return false;
    }

    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on Object {
      return false;
    }
  }
}
