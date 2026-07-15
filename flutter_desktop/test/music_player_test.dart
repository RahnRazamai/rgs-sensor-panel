import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rgs_sensor_panel_flutter/main.dart';
import 'package:rgs_sensor_panel_flutter/src/media/music_player_widget.dart';
import 'package:rgs_sensor_panel_flutter/src/media/rgs_windows_media.dart';
import 'package:rgs_sensor_panel_flutter/src/settings/panel_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('music widget kind is stable and sensor independent', () {
    expect(RgsWidgetKind.fromId('music'), RgsWidgetKind.music);
    expect(
      RgsWidgetKind.fromArgs(const ['--rgs-widget', 'music']),
      RgsWidgetKind.music,
    );
    expect(RgsWidgetKind.music.settingId, RgsPanelSettings.musicWidgetId);
    expect(RgsWidgetKind.music.requiresSensors, isFalse);
  });

  test('new and legacy settings keep music opt-in', () {
    final defaults = RgsPanelSettings.firstLaunchDefaults();
    expect(defaults.isVisible(RgsPanelSettings.musicWidgetId), isFalse);

    final legacy = RgsPanelSettings.fromJson(const {
      'HiddenDeviceIds': <String>[],
    });
    expect(legacy.isVisible(RgsPanelSettings.musicWidgetId), isFalse);

    final optedIn = RgsPanelSettings.fromJson(const {
      'SettingsVersion': 2,
      'HiddenDeviceIds': <String>[],
    });
    expect(optedIn.isVisible(RgsPanelSettings.musicWidgetId), isTrue);
  });

  test('media channel values are parsed and timeline is clamped', () {
    final snapshot = RgsMediaSnapshot.fromChannelValue(const {
      'available': true,
      'title': 'A track',
      'artist': 'An artist',
      'album': 'An album',
      'playbackState': 'playing',
      'positionMs': 90000,
      'durationMs': 60000,
      'canPrevious': true,
      'canTogglePlayPause': true,
      'canNext': false,
    });

    expect(snapshot.hasSession, isTrue);
    expect(snapshot.isPlaying, isTrue);
    expect(snapshot.position, const Duration(minutes: 1));
    expect(snapshot.progress, 1);
    expect(snapshot.canPrevious, isTrue);
    expect(snapshot.canNext, isFalse);
  });

  test('malformed media channel maps are unavailable', () {
    final snapshot = RgsMediaSnapshot.fromChannelValue(const {
      'title': 'Missing availability flag',
    });

    expect(snapshot.sessionState, RgsMediaSessionState.unavailable);
  });

  test('Windows controller maps channel reads and commands', () async {
    const channel = MethodChannel('rgs-media-test');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getSession') {
        return <String, Object?>{
          'available': true,
          'title': 'Channel track',
          'playbackState': 'paused',
          'canTogglePlayPause': true,
        };
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final controller = RgsWindowsMediaController(
      channel: channel,
      isWindows: true,
    );
    final snapshot = await controller.readSnapshot();
    expect(snapshot.title, 'Channel track');
    expect(snapshot.playbackState, RgsMediaPlaybackState.paused);
    expect(await controller.previous(), isTrue);
    expect(await controller.togglePlayPause(), isTrue);
    expect(await controller.next(), isTrue);
    expect(
      calls,
      ['getSession', 'previous', 'togglePlayPause', 'next'],
    );
  });

  testWidgets('music controls render and dispatch supported actions', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    // The real minimum window leaves 126 logical pixels after its 34-pixel
    // title bar and 14-pixel body padding on both sides.
    tester.view.physicalSize = const Size(292, 154);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    var previousCalls = 0;
    var toggleCalls = 0;
    var nextCalls = 0;
    const snapshot = RgsMediaSnapshot(
      sessionState: RgsMediaSessionState.active,
      status: 'Ready',
      title: 'A very long track title that must fit inside the compact widget',
      artist: 'Artist',
      album: 'Album',
      playbackState: RgsMediaPlaybackState.playing,
      position: Duration(minutes: 1, seconds: 5),
      duration: Duration(minutes: 3, seconds: 20),
      canPrevious: true,
      canTogglePlayPause: true,
      canNext: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(14),
            child: RgsMusicPlayerWidget(
              snapshot: snapshot,
              accent: const Color(0xFFD7A6FF),
              onPrevious: () => previousCalls++,
              onTogglePlayPause: () => toggleCalls++,
              onNext: () => nextCalls++,
            ),
          ),
        ),
      ),
    );

    expect(find.text(snapshot.title), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Previous track'));
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Next track'));
    expect(previousCalls, 1);
    expect(toggleCalls, 1);
    expect(nextCalls, 1);
  });

  testWidgets('unsupported music actions are disabled', (
    WidgetTester tester,
  ) async {
    const snapshot = RgsMediaSnapshot(
      sessionState: RgsMediaSessionState.active,
      status: 'Ready',
      title: 'Paused track',
      playbackState: RgsMediaPlaybackState.paused,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RgsMusicPlayerWidget(
            snapshot: snapshot,
            accent: Color(0xFFD7A6FF),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    final playButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
    );
    expect(playButton.onPressed, isNull);
  });

  testWidgets('music window polls its controller and dispatches commands', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(520, 360);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const windowChannel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
      if (call.method == 'getBounds') {
        return <String, double>{
          'x': 0,
          'y': 0,
          'width': 320,
          'height': 210,
        };
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });

    final controller = _FakeMediaController();
    await tester.pumpWidget(
      RgsSensorPanelApp(
        widgetKind: RgsWidgetKind.music,
        mediaController: controller,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.readCalls, greaterThanOrEqualTo(1));
    expect(find.text('Polled track'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(controller.toggleCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _FakeMediaController implements RgsMediaController {
  int readCalls = 0;
  int previousCalls = 0;
  int toggleCalls = 0;
  int nextCalls = 0;

  @override
  Future<RgsMediaSnapshot> readSnapshot() async {
    readCalls++;
    return const RgsMediaSnapshot(
      sessionState: RgsMediaSessionState.active,
      status: 'Ready',
      title: 'Polled track',
      artist: 'Polled artist',
      playbackState: RgsMediaPlaybackState.playing,
      position: Duration(seconds: 10),
      duration: Duration(minutes: 2),
      canPrevious: true,
      canTogglePlayPause: true,
      canNext: true,
    );
  }

  @override
  Future<bool> previous() async {
    previousCalls++;
    return true;
  }

  @override
  Future<bool> togglePlayPause() async {
    toggleCalls++;
    return true;
  }

  @override
  Future<bool> next() async {
    nextCalls++;
    return true;
  }
}
