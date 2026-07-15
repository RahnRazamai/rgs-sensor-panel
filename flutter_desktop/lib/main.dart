import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'firebase_options.dart';
import 'src/media/music_player_widget.dart';
import 'src/media/rgs_windows_media.dart';
import 'src/settings/panel_settings.dart';
import 'src/settings/startup_registration.dart';
import 'src/sensors/rgs_windows_sensors.dart';
import 'src/windows/windows_idle.dart';

const String koFiSupportUrl = 'https://ko-fi.com/rahngamingstudio';
const String youtubeSupportUrl = 'https://www.youtube.com/@rahngamingstudio';
const String githubSponsorUrl = 'https://github.com/sponsors/RahnRazamai';
const Duration widgetActiveRefreshInterval = Duration(seconds: 1);
const Duration widgetIdleRefreshInterval = Duration(seconds: 5);
const Duration widgetDisplayTimeoutLead = Duration(seconds: 15);
const Duration widgetFallbackPauseAfterIdle = Duration(seconds: 45);

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final launchConfig = await _readLaunchConfig(args);
  final widgetKind = launchConfig.widgetKind;
  final startHidden = launchConfig.startHidden;
  if (widgetKind == null) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  await _configureNativeWindow(widgetKind, startHidden: startHidden);

  runApp(
    RgsSensorPanelApp(
      widgetKind: widgetKind,
      startHidden: startHidden,
    ),
  );
}

final class RgsLaunchConfig {
  const RgsLaunchConfig({
    required this.widgetKind,
    required this.startHidden,
  });

  final RgsWidgetKind? widgetKind;
  final bool startHidden;
}

Future<RgsLaunchConfig> _readLaunchConfig(List<String> args) async {
  var widgetKind = RgsWidgetKind.fromArgs(args);
  final startHidden = widgetKind == null && args.contains('--rgs-startup');

  if (Platform.isWindows) {
    try {
      final controller = await WindowController.fromCurrentEngine();
      widgetKind =
          _widgetKindFromWindowArguments(controller.arguments) ?? widgetKind;
    } on Object {
      // Command-line arguments are still enough for normal startup and tests.
    }
  }

  return RgsLaunchConfig(
    widgetKind: widgetKind,
    startHidden: startHidden,
  );
}

String _widgetWindowArguments(RgsWidgetKind kind) {
  return jsonEncode({
    'type': 'widget',
    'kind': kind.id,
  });
}

RgsWidgetKind? _widgetKindFromWindowArguments(String arguments) {
  if (arguments.trim().isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(arguments);
    if (decoded is Map && decoded['type'] == 'widget') {
      return RgsWidgetKind.fromId(decoded['kind']?.toString() ?? '');
    }
  } on Object {
    return null;
  }

  return null;
}

extension RgsWindowControllerCommands on WindowController {
  Future<void> closeWidgetWindow() {
    return invokeMethod<void>('window_close');
  }
}

Future<void> _configureNativeWindow(
  RgsWidgetKind? widgetKind, {
  required bool startHidden,
}) async {
  if (!Platform.isWindows) {
    return;
  }

  await windowManager.ensureInitialized();
  final isWidget = widgetKind != null;
  final settings = RgsPanelSettings.load();
  final savedWidgetPosition =
      widgetKind == null ? null : settings.widgetPosition(widgetKind.settingId);
  final options = WindowOptions(
    size: isWidget ? const Size(320, 210) : const Size(420, 640),
    minimumSize: isWidget ? const Size(292, 188) : const Size(380, 520),
    center: !isWidget && !startHidden,
    title: isWidget ? widgetKind.windowTitle : 'RGS Sensor Control',
    titleBarStyle: isWidget ? TitleBarStyle.hidden : TitleBarStyle.normal,
    skipTaskbar: isWidget || startHidden,
    backgroundColor: isWidget ? Colors.transparent : const Color(0xFF111111),
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    if (isWidget) {
      await windowManager.setAlwaysOnTop(settings.alwaysOnTop);
      await windowManager.setOpacity(settings.widgetOpacity);
      if (savedWidgetPosition != null) {
        if (savedWidgetPosition.size != null) {
          await windowManager.setSize(savedWidgetPosition.size!);
        }
        await windowManager.setPosition(
          await _restoreWidgetPosition(savedWidgetPosition),
        );
      }
      await windowManager.show();
      return;
    }

    await windowManager.setPreventClose(true);
    if (startHidden) {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
      return;
    }

    await windowManager.show();
    await windowManager.focus();
  });
}

Future<Offset> _restoreWidgetPosition(RgsWidgetPosition position) async {
  final currentScale = _currentWindowScaleFactor();
  if (position.physicalLeft != null && position.physicalTop != null) {
    return Offset(
      position.physicalLeft! / currentScale,
      position.physicalTop! / currentScale,
    );
  }

  final legacyPosition = await _restoreLegacyWidgetPosition(
    position,
    currentScale,
  );
  if (legacyPosition != null) {
    return legacyPosition;
  }

  return Offset(position.left, position.top);
}

Future<Offset?> _restoreLegacyWidgetPosition(
  RgsWidgetPosition position,
  double currentScale,
) async {
  try {
    final displays = await screenRetriever.getAllDisplays();
    final display = _displayForPosition(
      Offset(position.left, position.top),
      displays,
    );
    if (display == null) {
      return null;
    }

    final displayScale = _displayScaleFactor(display);
    return Offset(
      position.left * displayScale / currentScale,
      position.top * displayScale / currentScale,
    );
  } on Object {
    return null;
  }
}

extension RgsWidgetPositionSize on RgsWidgetPosition {
  Size? get size {
    if (width == null || height == null) {
      return null;
    }

    return Size(width!, height!);
  }
}

Display? _displayForPosition(Offset position, List<Display> displays) {
  Display? nearestDisplay;
  var nearestDistance = double.infinity;

  for (final display in displays) {
    final rect = _displayRect(display);
    if (rect.contains(position)) {
      return display;
    }

    final distance = _distanceToRect(position, rect);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestDisplay = display;
    }
  }

  return nearestDisplay;
}

Rect _displayRect(Display display) {
  final origin = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  return origin & size;
}

double _distanceToRect(Offset position, Rect rect) {
  final dx = position.dx < rect.left
      ? rect.left - position.dx
      : position.dx > rect.right
          ? position.dx - rect.right
          : 0.0;
  final dy = position.dy < rect.top
      ? rect.top - position.dy
      : position.dy > rect.bottom
          ? position.dy - rect.bottom
          : 0.0;
  return dx * dx + dy * dy;
}

double _displayScaleFactor(Display display) {
  final scaleFactor = display.scaleFactor?.toDouble() ?? 1;
  return scaleFactor <= 0 ? 1 : scaleFactor;
}

double _currentWindowScaleFactor() {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) {
    return 1;
  }

  final scaleFactor = views.first.devicePixelRatio;
  return scaleFactor <= 0 ? 1 : scaleFactor;
}

bool _shouldPauseUiRefreshForIdle() {
  if (!Platform.isWindows) {
    return false;
  }

  try {
    final pauseAfter = _pauseRefreshAfterIdle();
    return pauseAfter != null && WindowsIdle.idleDuration() >= pauseAfter;
  } on Object {
    return false;
  }
}

Duration? _pauseRefreshAfterIdle() {
  final displayTimeout = WindowsIdle.displayIdleTimeout();
  if (displayTimeout == Duration.zero) {
    return null;
  }
  if (displayTimeout == null) {
    return widgetFallbackPauseAfterIdle;
  }

  final timeoutSeconds = displayTimeout.inSeconds;
  if (timeoutSeconds <= 0) {
    return null;
  }

  var thresholdSeconds = timeoutSeconds > widgetDisplayTimeoutLead.inSeconds * 2
      ? timeoutSeconds - widgetDisplayTimeoutLead.inSeconds
      : (timeoutSeconds * 0.75).round();
  if (thresholdSeconds < 1) {
    thresholdSeconds = 1;
  }
  if (thresholdSeconds > timeoutSeconds) {
    thresholdSeconds = timeoutSeconds;
  }

  return Duration(seconds: thresholdSeconds);
}

class RgsSensorPanelApp extends StatelessWidget {
  const RgsSensorPanelApp({
    super.key,
    required this.widgetKind,
    this.startHidden = false,
    this.pollSensors = true,
    this.mediaController,
  });

  final RgsWidgetKind? widgetKind;
  final bool startHidden;
  final bool pollSensors;
  final RgsMediaController? mediaController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widgetKind?.windowTitle ?? 'RGS Sensor Panel',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4ED6B8),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor:
            widgetKind == null ? const Color(0xFF111111) : Colors.transparent,
      ),
      home: widgetKind == null
          ? ControlPanelPage(
              pollSensors: pollSensors,
              startHidden: startHidden,
            )
          : WidgetWindowPage(
              kind: widgetKind!,
              pollSensors: pollSensors,
              mediaController: mediaController,
            ),
    );
  }
}

enum RgsWidgetKind {
  cpu,
  ram,
  gpu,
  ssd,
  time,
  music;

  static RgsWidgetKind? fromArgs(List<String> args) {
    for (var index = 0; index < args.length - 1; index++) {
      if (args[index] == '--rgs-widget') {
        return fromId(args[index + 1]);
      }
    }
    return null;
  }

  static RgsWidgetKind? fromId(String id) {
    for (final kind in values) {
      if (kind.id == id) {
        return kind;
      }
    }
    return null;
  }

  String get id => name;

  bool get requiresSensors {
    return switch (this) {
      RgsWidgetKind.cpu ||
      RgsWidgetKind.ram ||
      RgsWidgetKind.gpu ||
      RgsWidgetKind.ssd =>
        true,
      RgsWidgetKind.time || RgsWidgetKind.music => false,
    };
  }

  String get settingId {
    return switch (this) {
      RgsWidgetKind.cpu => RgsPanelSettings.cpuWidgetId,
      RgsWidgetKind.ram => RgsPanelSettings.ramWidgetId,
      RgsWidgetKind.gpu => RgsPanelSettings.gpuWidgetId,
      RgsWidgetKind.ssd => RgsPanelSettings.storageWidgetId,
      RgsWidgetKind.time => RgsPanelSettings.clockWidgetId,
      RgsWidgetKind.music => RgsPanelSettings.musicWidgetId,
    };
  }

  String get label {
    return switch (this) {
      RgsWidgetKind.cpu => 'CPU',
      RgsWidgetKind.ram => 'RAM',
      RgsWidgetKind.gpu => 'GPU',
      RgsWidgetKind.ssd => 'SSD',
      RgsWidgetKind.time => 'Date and time',
      RgsWidgetKind.music => 'Music player',
    };
  }

  String get windowTitle {
    return switch (this) {
      RgsWidgetKind.cpu => 'CPU',
      RgsWidgetKind.ram => 'RAM',
      RgsWidgetKind.gpu => 'GPU',
      RgsWidgetKind.ssd => 'SSD',
      RgsWidgetKind.time => 'TIME',
      RgsWidgetKind.music => 'MUSIC',
    };
  }

  Color get accent {
    return switch (this) {
      RgsWidgetKind.cpu => const Color(0xFF4ED6B8),
      RgsWidgetKind.ram => const Color(0xFFF5B84B),
      RgsWidgetKind.gpu => const Color(0xFF8FB8FF),
      RgsWidgetKind.ssd => const Color(0xFFFF6F61),
      RgsWidgetKind.time => const Color(0xFFC9E265),
      RgsWidgetKind.music => const Color(0xFFD7A6FF),
    };
  }
}

class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({
    super.key,
    this.startHidden = false,
    this.pollSensors = true,
  });

  final bool startHidden;
  final bool pollSensors;

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage>
    with WindowListener, TrayListener {
  RgsSensorSnapshot _snapshot = RgsSensorSnapshot.unavailable('Starting...');
  RgsPanelSettings _settings = RgsPanelSettings.load();
  final Map<RgsWidgetKind, WindowController> _widgetWindows = {};
  final Set<RgsWidgetKind> _visibleWidgets = {};
  final Set<RgsWidgetKind> _pendingWidgetLaunches = {};
  StreamSubscription<void>? _windowSubscription;
  Timer? _timer;
  bool _enablingSensors = false;
  bool _isQuitting = false;
  bool _launchingPendingWidgets = false;
  bool _refreshInProgress = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows && widget.pollSensors) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      unawaited(_setupTray());
      unawaited(_syncStartupRegistration());
      _windowSubscription = onWindowsChanged.listen(
        (_) => unawaited(_syncWidgetWindowControllers()),
      );
    }

    if (!widget.pollSensors) {
      return;
    }
    unawaited(_runRefreshTick());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.startHidden) {
        unawaited(_hideToTray());
      }
      unawaited(_launchConfiguredWidgets());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_windowSubscription?.cancel());
    if (Platform.isWindows && widget.pollSensors) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _setupTray() async {
    await trayManager.setIcon('assets/rgs-sensor-panel-ico.ico');
    await trayManager.setToolTip('RGS Sensor Panel');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'settings', label: 'Settings'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Exit'),
        ],
      ),
    );
  }

  Future<void> _hideToTray() async {
    if (!Platform.isWindows || _isQuitting) {
      return;
    }

    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> _showFromTray() async {
    if (!Platform.isWindows) {
      return;
    }

    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exitApplication() async {
    _isQuitting = true;
    for (final controller in _widgetWindows.values.toList()) {
      await _closeWidgetWindow(controller);
    }
    _widgetWindows.clear();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onWindowClose() {
    if (_isQuitting) {
      return;
    }

    unawaited(_hideToTray());
  }

  @override
  void onWindowMinimize() {
    if (_isQuitting) {
      return;
    }

    unawaited(_hideToTray());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'settings':
        unawaited(_showFromTray());
        break;
      case 'exit':
        unawaited(_exitApplication());
        break;
    }
  }

  Future<void> _refresh() async {
    if (_refreshInProgress) {
      return;
    }

    _refreshInProgress = true;
    try {
      final snapshot = await RgsWindowsSensors.instance.readSnapshot();
      final settings = RgsPanelSettings.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _settings = settings;
      });
      if (snapshot.available) {
        unawaited(_launchPendingWidgetsIfReady());
      }
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _runRefreshTick() async {
    if (!mounted || !widget.pollSensors) {
      return;
    }

    final pausedForIdle = _shouldPauseUiRefreshForIdle();
    if (!pausedForIdle) {
      await _refresh();
    }

    _scheduleRefreshTick(
      pausedForIdle ? widgetIdleRefreshInterval : widgetActiveRefreshInterval,
    );
  }

  void _scheduleRefreshTick(Duration delay) {
    _timer?.cancel();
    if (!mounted || !widget.pollSensors) {
      return;
    }

    _timer = Timer(delay, () => unawaited(_runRefreshTick()));
  }

  Future<void> _enableSensors() async {
    setState(() => _enablingSensors = true);
    final result = await RgsWindowsSensors.instance.enableBackgroundSensors();
    if (!mounted) {
      return;
    }
    setState(() => _enablingSensors = false);
    await _refresh();
    if (!result.enabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }

  Future<void> _launchConfiguredWidgets() async {
    for (final kind in RgsWidgetKind.values) {
      if (_settings.isVisible(kind.settingId)) {
        await _setWidgetVisible(kind, true, save: false);
      }
    }
  }

  Future<void> _syncWidgetWindowControllers() async {
    if (!Platform.isWindows) {
      return;
    }

    try {
      final controllers = await WindowController.getAll();
      final widgetWindows = <RgsWidgetKind, WindowController>{};
      for (final controller in controllers) {
        final kind = _widgetKindFromWindowArguments(controller.arguments);
        if (kind != null) {
          widgetWindows[kind] = controller;
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _widgetWindows
          ..clear()
          ..addAll(widgetWindows);
        _visibleWidgets
          ..clear()
          ..addAll(widgetWindows.keys);
        _settings = RgsPanelSettings.load();
      });
    } on Object {
      // The next window event or refresh will try again.
    }
  }

  Future<void> _launchPendingWidgetsIfReady() async {
    if (_launchingPendingWidgets || !_snapshot.available) {
      return;
    }

    _launchingPendingWidgets = true;
    try {
      final pendingWidgets = _pendingWidgetLaunches
          .where((kind) => _settings.isVisible(kind.settingId))
          .toList();
      _pendingWidgetLaunches.clear();
      for (final kind in pendingWidgets) {
        await _setWidgetVisible(kind, true, save: false);
      }
    } finally {
      _launchingPendingWidgets = false;
    }
  }

  Future<void> _setWidgetVisible(
    RgsWidgetKind kind,
    bool visible, {
    bool save = true,
  }) async {
    if (save) {
      _settings.setVisible(kind.settingId, visible);
      _settings.save();
    }

    if (visible) {
      if (kind.requiresSensors && !_snapshot.available) {
        _pendingWidgetLaunches.add(kind);
        if (mounted) {
          setState(() {});
        }
        return;
      }

      if (_widgetWindows.containsKey(kind)) {
        setState(() => _visibleWidgets.add(kind));
        return;
      }

      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: _widgetWindowArguments(kind),
          hiddenAtLaunch: true,
        ),
      );
      setState(() {
        _widgetWindows[kind] = controller;
        _visibleWidgets.add(kind);
      });
      return;
    }

    _pendingWidgetLaunches.remove(kind);
    final controller = _widgetWindows.remove(kind);
    if (controller != null) {
      await _closeWidgetWindow(controller);
    }
    setState(() => _visibleWidgets.remove(kind));
  }

  Future<void> _closeWidgetWindow(WindowController controller) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await controller.closeWidgetWindow();
        return;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    try {
      await controller.hide();
    } on Object {
      // The window may already be gone.
    }
  }

  Future<void> _showAll() async {
    _settings.showAll();
    _settings.save();
    for (final kind in RgsWidgetKind.values) {
      await _setWidgetVisible(kind, true, save: false);
    }
    await _refresh();
  }

  void _setPreference(void Function(RgsPanelSettings settings) update) {
    setState(() {
      update(_settings);
      _settings.save();
    });
  }

  Future<void> _setAutoLaunch(bool value) async {
    final previousValue = _settings.autoLaunchOnBoot;
    setState(() => _settings.autoLaunchOnBoot = value);

    final result = await RgsStartupRegistration.setEnabled(value);
    if (!mounted) {
      return;
    }

    if (result.success) {
      _settings.save();
      return;
    }

    setState(() => _settings.autoLaunchOnBoot = previousValue);
    _settings.save();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _syncStartupRegistration() async {
    final result = await RgsStartupRegistration.setEnabled(
      _settings.autoLaunchOnBoot,
    );
    if (!mounted || result.success || !_settings.autoLaunchOnBoot) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  void _setDeviceVisible(String id, bool visible) {
    setState(() {
      _settings.setVisible(id, visible);
      _settings.save();
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CONTROL PANEL',
                          style: TextStyle(
                            color: Color(0xFFBABAB7),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'RGS SENSOR PANEL',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _StatusPill(snapshot: snapshot),
                ],
              ),
              const SizedBox(height: 18),
              if (!snapshot.available || !snapshot.hasSystemMetrics)
                _EnableSensorsCard(
                  status: snapshot.status,
                  busy: _enablingSensors,
                  onPressed: _enableSensors,
                ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    const _SectionHeader('APP'),
                    SwitchListTile(
                      value: _settings.minimizeToTrayOnClose,
                      onChanged: (value) => _setPreference(
                        (settings) => settings.minimizeToTrayOnClose = value,
                      ),
                      title: const Text('Run in background when closed'),
                    ),
                    SwitchListTile(
                      value: _settings.autoLaunchOnBoot,
                      onChanged: (value) => unawaited(_setAutoLaunch(value)),
                      title: const Text('Auto launch on boot'),
                    ),
                    SwitchListTile(
                      value: _settings.alwaysOnTop,
                      onChanged: (value) => _setPreference(
                        (settings) => settings.alwaysOnTop = value,
                      ),
                      title: const Text('Keep widgets always on top'),
                    ),
                    _OpacitySlider(
                      value: _settings.widgetOpacity,
                      onChanged: (value) => _setPreference(
                        (settings) => settings.widgetOpacity = value,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const _SectionHeader('WIDGETS'),
                    for (final kind in RgsWidgetKind.values)
                      ..._buildWidgetOptions(kind, snapshot),
                    const SizedBox(height: 8),
                    _SupportPanel(
                      expanded: _settings.showSupportPanel,
                      onToggle: () => _setPreference(
                        (settings) => settings.showSupportPanel =
                            !settings.showSupportPanel,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _showAll,
                    child: const Text('Show All'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _hideToTray,
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildWidgetOptions(
    RgsWidgetKind kind,
    RgsSensorSnapshot snapshot,
  ) {
    final widgets = <Widget>[
      CheckboxListTile(
        value: _settings.isVisible(kind.settingId),
        onChanged: (value) => _setWidgetVisible(kind, value ?? false),
        title: Text(kind.label),
        secondary: Icon(Icons.crop_square, color: kind.accent),
      ),
    ];

    if (kind == RgsWidgetKind.gpu) {
      widgets.addAll([
        for (final gpu in snapshot.gpus.where(_isNotGenericGpu))
          _DeviceVisibilityTile(
            name: gpu.name,
            visible: _settings.isVisible(gpu.id),
            accent: kind.accent,
            onChanged: (value) => _setDeviceVisible(gpu.id, value),
          ),
      ]);
    }

    if (kind == RgsWidgetKind.ssd) {
      widgets.addAll([
        for (final drive in snapshot.storage)
          _DeviceVisibilityTile(
            name: drive.name,
            visible: _settings.isVisible(drive.id),
            accent: kind.accent,
            onChanged: (value) => _setDeviceVisible(drive.id, value),
          ),
      ]);
    }

    return widgets;
  }
}

class WidgetWindowPage extends StatefulWidget {
  const WidgetWindowPage({
    super.key,
    required this.kind,
    this.pollSensors = true,
    this.mediaController,
  });

  final RgsWidgetKind kind;
  final bool pollSensors;
  final RgsMediaController? mediaController;

  @override
  State<WidgetWindowPage> createState() => _WidgetWindowPageState();
}

class _WidgetWindowPageState extends State<WidgetWindowPage>
    with WindowListener {
  static const _maxMissedRefreshesBeforeLoading = 4;

  RgsSensorSnapshot _snapshot = RgsSensorSnapshot.unavailable('Starting...');
  RgsMediaSnapshot _mediaSnapshot = const RgsMediaSnapshot.loading();
  RgsPanelSettings _settings = RgsPanelSettings.load();
  Timer? _timer;
  bool _showVisibilityPanel = false;
  Size? _lastAppliedSize;
  bool _applyingWindowSize = false;
  bool _refreshInProgress = false;
  bool _mediaCommandInProgress = false;
  int _missedRefreshes = 0;
  WindowController? _windowController;

  late final RgsMediaController _mediaController =
      widget.mediaController ?? RgsWindowsMediaController.instance;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows && widget.pollSensors) {
      windowManager.addListener(this);
      unawaited(_setupWindowController());
    }
    if (!widget.pollSensors) {
      return;
    }
    unawaited(_runWidgetTick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_windowController?.setWindowMethodHandler(null));
    if (Platform.isWindows && widget.pollSensors) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _setupWindowController() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      _windowController = controller;
      await controller.setWindowMethodHandler((call) async {
        if (call.method == 'window_close') {
          await windowManager.close();
        }
        return null;
      });
    } on Object {
      // Standalone --rgs-widget launches do not need cross-window commands.
    }
  }

  @override
  void onWindowMoved() {
    unawaited(_saveWidgetPlacement());
  }

  @override
  void onWindowResized() {
    if (_applyingWindowSize) {
      return;
    }

    unawaited(_saveWidgetPlacement());
  }

  Future<void> _refresh() async {
    if (_refreshInProgress) {
      return;
    }

    _refreshInProgress = true;
    try {
      final snapshot = await RgsWindowsSensors.instance.readSnapshot(
        tryStartExistingTask: false,
      );
      final settings = RgsPanelSettings.load();
      if (!mounted) {
        return;
      }

      final shouldShowSnapshot = snapshot.available ||
          !_snapshot.available ||
          _missedRefreshes >= _maxMissedRefreshesBeforeLoading;
      final displaySnapshot = shouldShowSnapshot ? snapshot : _snapshot;
      setState(() {
        if (snapshot.available) {
          _missedRefreshes = 0;
        } else {
          _missedRefreshes++;
        }
        if (shouldShowSnapshot) {
          _snapshot = snapshot;
        }
        _settings = settings;
      });
      await _applyWindowPreferences(settings, displaySnapshot);
      await _syncManualWidgetPlacement(settings, displaySnapshot);
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _refreshClock() async {
    final settings = RgsPanelSettings.load();
    final snapshot = RgsSensorSnapshot.unavailable('Clock ready');
    if (!mounted) {
      return;
    }

    setState(() {
      _snapshot = snapshot;
      _settings = settings;
    });
    await _applyWindowPreferences(settings, snapshot);
    await _syncManualWidgetPlacement(settings, snapshot);
  }

  Future<void> _refreshMedia() async {
    if (_refreshInProgress) {
      return;
    }

    _refreshInProgress = true;
    try {
      final mediaSnapshot = await _mediaController.readSnapshot();
      final settings = RgsPanelSettings.load();
      if (!mounted) {
        return;
      }

      setState(() {
        _mediaSnapshot = mediaSnapshot;
        _settings = settings;
      });
      await _applyWindowPreferences(settings, _snapshot);
      await _syncManualWidgetPlacement(settings, _snapshot);
    } finally {
      _refreshInProgress = false;
    }
  }

  Future<void> _runMediaCommand(Future<bool> Function() command) async {
    if (_mediaCommandInProgress) {
      return;
    }

    setState(() => _mediaCommandInProgress = true);
    try {
      await command();
      await _refreshMedia();
    } finally {
      if (mounted) {
        setState(() => _mediaCommandInProgress = false);
      }
    }
  }

  Future<void> _runWidgetTick() async {
    if (!mounted || !widget.pollSensors) {
      return;
    }

    final pausedForIdle =
        widget.kind != RgsWidgetKind.music && _shouldPauseUiRefreshForIdle();
    if (!pausedForIdle) {
      switch (widget.kind) {
        case RgsWidgetKind.cpu:
        case RgsWidgetKind.ram:
        case RgsWidgetKind.gpu:
        case RgsWidgetKind.ssd:
          await _refresh();
        case RgsWidgetKind.time:
          await _refreshClock();
        case RgsWidgetKind.music:
          await _refreshMedia();
      }
    }

    _scheduleWidgetTick(
      pausedForIdle ? widgetIdleRefreshInterval : widgetActiveRefreshInterval,
    );
  }

  void _scheduleWidgetTick(Duration delay) {
    _timer?.cancel();
    if (!mounted || !widget.pollSensors) {
      return;
    }

    _timer = Timer(delay, () => unawaited(_runWidgetTick()));
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final action = _buildAction(kind);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xF2161616),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF343434)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => windowManager.startDragging(),
                onPanEnd: (_) => unawaited(_saveWidgetPlacement()),
                onPanCancel: () => unawaited(_saveWidgetPlacement()),
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.only(left: 12, right: 6),
                  color: const Color(0xFF101010),
                  child: Row(
                    children: [
                      Text(
                        kind.windowTitle,
                        style: TextStyle(
                          color: kind.accent,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0,
                        ),
                      ),
                      const Spacer(),
                      if (action != null)
                        _TinyButton(
                          label: action.label,
                          tooltip: action.tooltip,
                          onPressed: action.onPressed,
                        ),
                      _TinyButton(
                        label: 'X',
                        tooltip: 'Hide',
                        onPressed: _hideThisWidget,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _WidgetContent(
                    kind: kind,
                    snapshot: _snapshot,
                    mediaSnapshot: _mediaSnapshot,
                    mediaBusy: _mediaCommandInProgress,
                    settings: _settings,
                    showVisibilityPanel: _showVisibilityPanel,
                    onDeviceVisibilityChanged: _setDeviceVisible,
                    onPrevious: () => unawaited(
                      _runMediaCommand(_mediaController.previous),
                    ),
                    onTogglePlayPause: () => unawaited(
                      _runMediaCommand(_mediaController.togglePlayPause),
                    ),
                    onNext: () => unawaited(
                      _runMediaCommand(_mediaController.next),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _WidgetAction? _buildAction(RgsWidgetKind kind) {
    if (kind == RgsWidgetKind.time) {
      return _WidgetAction(
        label: _settings.useTwentyFourHourClock ? '12' : '24',
        tooltip: _settings.useTwentyFourHourClock
            ? 'Switch to 12-hour time'
            : 'Switch to 24-hour time',
        onPressed: () {
          setState(() {
            _settings.useTwentyFourHourClock =
                !_settings.useTwentyFourHourClock;
            _settings.save();
          });
        },
      );
    }

    if (kind == RgsWidgetKind.gpu &&
        _snapshot.gpus.where(_isNotGenericGpu).length > 1) {
      return _WidgetAction(
        label: 'V',
        tooltip: 'Show or hide GPU readings',
        onPressed: () {
          setState(() => _showVisibilityPanel = !_showVisibilityPanel);
          unawaited(_applyWindowPreferences(_settings, _snapshot));
        },
      );
    }

    if (kind == RgsWidgetKind.ssd && _snapshot.storage.length > 1) {
      return _WidgetAction(
        label: 'V',
        tooltip: 'Show or hide SSD readings',
        onPressed: () {
          setState(() => _showVisibilityPanel = !_showVisibilityPanel);
          unawaited(_applyWindowPreferences(_settings, _snapshot));
        },
      );
    }

    return null;
  }

  Future<void> _applyWindowPreferences(
    RgsPanelSettings settings,
    RgsSensorSnapshot snapshot,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    await windowManager.setAlwaysOnTop(settings.alwaysOnTop);
    await windowManager.setOpacity(settings.widgetOpacity);
    final savedSize = settings.widgetPosition(widget.kind.settingId)?.size;
    final targetSize = savedSize ?? _targetWidgetSize(snapshot);
    if (_lastAppliedSize == targetSize) {
      return;
    }

    _lastAppliedSize = targetSize;
    _applyingWindowSize = true;
    try {
      await windowManager.setSize(targetSize);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } finally {
      _applyingWindowSize = false;
    }
  }

  Future<void> _syncManualWidgetPlacement(
    RgsPanelSettings settings,
    RgsSensorSnapshot snapshot,
  ) async {
    if (!Platform.isWindows || _applyingWindowSize) {
      return;
    }

    final expectedSize = settings.widgetPosition(widget.kind.settingId)?.size ??
        _targetWidgetSize(snapshot);
    final currentSize = await windowManager.getSize();
    if (_isCloseSize(currentSize, expectedSize)) {
      return;
    }

    await _saveWidgetPlacement();
  }

  bool _isCloseSize(Size a, Size b) {
    return (a.width - b.width).abs() < 1 && (a.height - b.height).abs() < 1;
  }

  Size _targetWidgetSize(RgsSensorSnapshot snapshot) {
    var rowCount = 1;
    if (widget.kind == RgsWidgetKind.gpu) {
      rowCount = _showVisibilityPanel
          ? snapshot.gpus.where(_isNotGenericGpu).length
          : snapshot.gpus
              .where(
                  (gpu) => _isNotGenericGpu(gpu) && _settings.isVisible(gpu.id))
              .length;
    } else if (widget.kind == RgsWidgetKind.ssd) {
      rowCount = _showVisibilityPanel
          ? snapshot.storage.length
          : snapshot.storage
              .where((drive) => _settings.isVisible(drive.id))
              .length;
    }

    final height = rowCount <= 1
        ? 210.0
        : (92 + rowCount * 106).clamp(220, 560).toDouble();
    return Size(320, height);
  }

  void _setDeviceVisible(String id, bool visible) {
    setState(() {
      _settings.setVisible(id, visible);
      _settings.save();
    });
    unawaited(_applyWindowPreferences(_settings, _snapshot));
  }

  Future<void> _saveWidgetPlacement() async {
    if (!Platform.isWindows) {
      return;
    }

    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    final scaleFactor = _currentWindowScaleFactor();
    final settings = RgsPanelSettings.load();
    settings.setWidgetPosition(
      widget.kind.settingId,
      position.dx,
      position.dy,
      width: size.width,
      height: size.height,
      physicalLeft: position.dx * scaleFactor,
      physicalTop: position.dy * scaleFactor,
      scaleFactor: scaleFactor,
    );
    settings.save();
    _settings = settings;
    _lastAppliedSize = size;
  }

  Future<void> _hideThisWidget() async {
    await _saveWidgetPlacement();
    _settings.setVisible(widget.kind.settingId, false);
    _settings.save();
    await windowManager.close();
  }
}

class _WidgetContent extends StatelessWidget {
  const _WidgetContent({
    required this.kind,
    required this.snapshot,
    required this.mediaSnapshot,
    required this.mediaBusy,
    required this.settings,
    required this.showVisibilityPanel,
    required this.onDeviceVisibilityChanged,
    required this.onPrevious,
    required this.onTogglePlayPause,
    required this.onNext,
  });

  final RgsWidgetKind kind;
  final RgsSensorSnapshot snapshot;
  final RgsMediaSnapshot mediaSnapshot;
  final bool mediaBusy;
  final RgsPanelSettings settings;
  final bool showVisibilityPanel;
  final void Function(String id, bool visible) onDeviceVisibilityChanged;
  final VoidCallback onPrevious;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final gpus = snapshot.gpus
        .where((gpu) => _isNotGenericGpu(gpu) && settings.isVisible(gpu.id))
        .toList();
    final drives = snapshot.storage
        .where((drive) => settings.isVisible(drive.id))
        .toList();

    if (kind.requiresSensors && !snapshot.available) {
      return _LoadingWidget(
        accent: kind.accent,
        title: 'Loading sensors',
        message: _sensorLoadingMessage(snapshot.status),
      );
    }

    if (showVisibilityPanel && kind == RgsWidgetKind.gpu) {
      return _VisibilityPanel(
        emptyLabel: 'No GPU sensors',
        rows: [
          for (final gpu in snapshot.gpus.where(_isNotGenericGpu))
            _VisibilityRow(
              id: gpu.id,
              name: gpu.name,
              visible: settings.isVisible(gpu.id),
            ),
        ],
        onChanged: onDeviceVisibilityChanged,
      );
    }

    if (showVisibilityPanel && kind == RgsWidgetKind.ssd) {
      return _VisibilityPanel(
        emptyLabel: 'No SSD sensors',
        rows: [
          for (final drive in snapshot.storage)
            _VisibilityRow(
              id: drive.id,
              name: drive.name,
              visible: settings.isVisible(drive.id),
            ),
        ],
        onChanged: onDeviceVisibilityChanged,
      );
    }

    return switch (kind) {
      RgsWidgetKind.cpu => _SingleStatWidget(
          value: _percent(snapshot.cpu.load),
          subtitle: snapshot.cpu.name ?? 'Processor',
          percent: snapshot.cpu.load,
          accent: kind.accent,
          stats: [
            _Stat('TEMP', _temperature(snapshot.cpu.temperature)),
            _Stat('POWER', _power(snapshot.cpu.power)),
            _Stat('CLOCK', _clock(snapshot.cpu.clock)),
          ],
        ),
      RgsWidgetKind.ram => _SingleStatWidget(
          value: _percent(snapshot.memory.load),
          subtitle: snapshot.memory.name ?? 'Physical RAM',
          percent: snapshot.memory.load,
          accent: kind.accent,
          stats: [
            _Stat('USED', _bytes(snapshot.memory.usedBytes)),
            _Stat('TOTAL', _bytes(snapshot.memory.totalBytes)),
            _Stat('SPEED',
                _memorySpeed(snapshot.memory.speed ?? snapshot.memory.clock)),
          ],
        ),
      RgsWidgetKind.gpu => _gpuContent(gpus),
      RgsWidgetKind.ssd => _ssdContent(drives),
      RgsWidgetKind.time => _SingleStatWidget(
          value: _time(snapshot.timestamp, settings.useTwentyFourHourClock),
          subtitle: _date(snapshot.timestamp),
          percent: null,
          accent: kind.accent,
          showProgress: false,
          stats: [
            _Stat('DAY', _day(snapshot.timestamp)),
            _Stat('DATE', _shortDate(snapshot.timestamp)),
            _Stat('YEAR', '${snapshot.timestamp.year}'),
          ],
        ),
      RgsWidgetKind.music => RgsMusicPlayerWidget(
          snapshot: mediaSnapshot,
          accent: kind.accent,
          busy: mediaBusy,
          onPrevious: onPrevious,
          onTogglePlayPause: onTogglePlayPause,
          onNext: onNext,
        ),
    };
  }

  Widget _gpuContent(List<RgsGpuReading> gpus) {
    if (gpus.length == 1) {
      final gpu = gpus.single;
      return _SingleStatWidget(
        value: _percent(gpu.load),
        subtitle: gpu.load == null ? '${gpu.name} unavailable' : gpu.name,
        percent: gpu.load,
        accent: kind.accent,
        stats: [
          _Stat('TEMP', _temperature(gpu.temperature)),
          _Stat('POWER', _power(gpu.power)),
          _Stat('CLOCK', _clock(gpu.clock)),
        ],
      );
    }

    return _RowsWidget(
      emptyLabel: 'No GPU sensors selected',
      summary: '${gpus.length} GPU shown',
      accent: kind.accent,
      rows: [
        for (final gpu in gpus)
          _GroupRow(
            name: gpu.name,
            value: _percent(gpu.load),
            subValue: gpu.load == null
                ? 'Counter unavailable'
                : 'GPU engine utilization',
            percent: gpu.load,
            stat1: 'TEMP ${_temperature(gpu.temperature)}',
            stat2: 'PWR ${_power(gpu.power)}',
            stat3: _clock(gpu.clock),
          ),
      ],
    );
  }

  Widget _ssdContent(List<RgsStorageReading> drives) {
    if (drives.length == 1) {
      final drive = drives.single;
      return _SingleStatWidget(
        value: drive.percent == null
            ? _temperature(drive.temperature)
            : _percent(drive.percent),
        subtitle: _storageSubtitle(drive),
        percent: drive.percent,
        accent: kind.accent,
        stats: [
          _Stat('TEMP', _temperature(drive.temperature)),
          _Stat('READ', _rate(drive.readBytesPerSecond)),
          _Stat('WRITE', _rate(drive.writeBytesPerSecond)),
        ],
      );
    }

    return _RowsWidget(
      emptyLabel: 'No SSD sensors selected',
      summary: '${drives.length} SSD shown',
      accent: kind.accent,
      rows: [
        for (final drive in drives)
          _GroupRow(
            name: drive.name,
            value: drive.percent == null
                ? _temperature(drive.temperature)
                : _percent(drive.percent),
            subValue: _storageSubValue(drive),
            percent: drive.percent,
            stat1: 'TEMP ${_temperature(drive.temperature)}',
            stat2: 'READ ${_rate(drive.readBytesPerSecond)}',
            stat3: 'WRITE ${_rate(drive.writeBytesPerSecond)}',
          ),
      ],
    );
  }
}

class _LoadingWidget extends StatelessWidget {
  const _LoadingWidget({
    required this.accent,
    required this.title,
    required this.message,
  });

  final Color accent;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 4,
              color: accent,
              backgroundColor: const Color(0xFF101010),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFBABAB7),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _SingleStatWidget extends StatelessWidget {
  const _SingleStatWidget({
    required this.value,
    required this.subtitle,
    required this.percent,
    required this.accent,
    required this.stats,
    this.showProgress = true,
  });

  final String value;
  final String subtitle;
  final double? percent;
  final Color accent;
  final List<_Stat> stats;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 38, fontWeight: FontWeight.bold),
              ),
            ),
            if (showProgress)
              SizedBox(
                width: 50,
                height: 50,
                child: _RingProgress(percent: percent, color: accent),
              ),
          ],
        ),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFBABAB7), fontSize: 12),
        ),
        const Spacer(),
        Row(
          children: [
            for (final stat in stats)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stat.label,
                      style: const TextStyle(
                          color: Color(0xFF858585), fontSize: 10),
                    ),
                    Text(
                      stat.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _RowsWidget extends StatelessWidget {
  const _RowsWidget({
    required this.rows,
    required this.emptyLabel,
    required this.summary,
    required this.accent,
  });

  final List<_GroupRow> rows;
  final String emptyLabel;
  final String summary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child:
            Text(emptyLabel, style: const TextStyle(color: Color(0xFFBABAB7))),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFFBABAB7), fontSize: 12),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final row in rows)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF343434)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(row.value,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          row.subValue,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFFBABAB7), fontSize: 11),
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: row.percent == null
                            ? 0
                            : (row.percent!.clamp(0, 100) / 100),
                        minHeight: 8,
                        color: accent,
                        backgroundColor: const Color(0xFF101010),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.stat1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              row.stat2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              row.stat3,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RingProgress extends StatelessWidget {
  const _RingProgress({
    required this.percent,
    required this.color,
  });

  final double? percent;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final value = percent == null ? 0.0 : (percent!.clamp(0, 100) / 100);
    return Stack(
      fit: StackFit.expand,
      children: [
        const CircularProgressIndicator(
          value: 1,
          strokeWidth: 6,
          color: Color(0xFF101010),
          backgroundColor: Colors.transparent,
        ),
        CircularProgressIndicator(
          value: value,
          strokeWidth: 6,
          color: color,
          backgroundColor: Colors.transparent,
        ),
      ],
    );
  }
}

class _VisibilityPanel extends StatelessWidget {
  const _VisibilityPanel({
    required this.emptyLabel,
    required this.rows,
    required this.onChanged,
  });

  final String emptyLabel;
  final List<_VisibilityRow> rows;
  final void Function(String id, bool visible) onChanged;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child:
            Text(emptyLabel, style: const TextStyle(color: Color(0xFFBABAB7))),
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final row in rows)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: row.visible,
            onChanged: (value) => onChanged(row.id, value ?? false),
            title: Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
    );
  }
}

class _DeviceVisibilityTile extends StatelessWidget {
  const _DeviceVisibilityTile({
    required this.name,
    required this.visible,
    required this.accent,
    required this.onChanged,
  });

  final String name;
  final bool visible;
  final Color accent;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      value: visible,
      onChanged: (value) => onChanged(value ?? false),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      secondary: Icon(Icons.devices, color: accent, size: 18),
    );
  }
}

class _WidgetAction {
  const _WidgetAction({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;
}

class _VisibilityRow {
  const _VisibilityRow({
    required this.id,
    required this.name,
    required this.visible,
  });

  final String id;
  final String name;
  final bool visible;
}

class _EnableSensorsCard extends StatelessWidget {
  const _EnableSensorsCard({
    required this.status,
    required this.busy,
    required this.onPressed,
  });

  final String status;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF221C19),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.sensors_off),
            const SizedBox(width: 12),
            Expanded(child: Text(status)),
            FilledButton(
              onPressed: busy ? null : onPressed,
              child: Text(busy ? 'Enabling...' : 'Enable sensors'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.snapshot});

  final RgsSensorSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: snapshot.available
            ? const Color(0xFF123B32)
            : const Color(0xFF402822),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: snapshot.available
              ? const Color(0xFF4ED6B8)
              : const Color(0xFFFF8A65),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(snapshot.available ? 'Live' : 'Offline'),
      ),
    );
  }
}

class _OpacitySlider extends StatelessWidget {
  const _OpacitySlider({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Widget opacity')),
              Text('${(value * 100).round()}%'),
            ],
          ),
          Slider(
            value: value.clamp(0.35, 1),
            min: 0.35,
            max: 1,
            divisions: 13,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SupportPanel extends StatelessWidget {
  const _SupportPanel({
    required this.expanded,
    required this.onToggle,
  });

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF201F1C),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Support',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                OutlinedButton(
                  onPressed: onToggle,
                  child: Text(expanded ? 'Shrink' : 'Expand'),
                ),
              ],
            ),
            if (expanded) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => _openUrl(koFiSupportUrl),
                  child: Image.asset(
                    'assets/support_me_on_kofi_beige.png',
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => _openUrl(youtubeSupportUrl),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB91C1C)),
                child: const Text('Subscribe on YouTube'),
              ),
              OutlinedButton(
                onPressed: () => _openUrl(githubSponsorUrl),
                child: const Text('Sponsor on GitHub'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TinyButton extends StatelessWidget {
  const _TinyButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 26,
        height: 24,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: const Color(0xFFF8F8F6),
          ),
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFA7A7A7),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value);

  final String label;
  final String value;
}

class _GroupRow {
  const _GroupRow({
    required this.name,
    required this.value,
    required this.subValue,
    required this.percent,
    required this.stat1,
    required this.stat2,
    required this.stat3,
  });

  final String name;
  final String value;
  final String subValue;
  final double? percent;
  final String stat1;
  final String stat2;
  final String stat3;
}

Future<void> _openUrl(String url) async {
  if (Platform.isWindows) {
    await Process.start('cmd', ['/c', 'start', '', url],
        mode: ProcessStartMode.detached);
    return;
  }

  if (Platform.isMacOS) {
    await Process.start('open', [url], mode: ProcessStartMode.detached);
    return;
  }

  await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
}

String _percent(double? value) =>
    value == null ? 'N/A' : '${value.toStringAsFixed(0)}%';
String _temperature(double? value) =>
    value == null ? '-- C' : '${value.toStringAsFixed(0)} C';
String _power(double? value) =>
    value == null ? '-- W' : '${value.toStringAsFixed(0)} W';

String _sensorLoadingMessage(String status) {
  final normalized = status.toLowerCase();
  if (normalized.contains('not found') ||
      normalized.contains('only available')) {
    return status;
  }

  return 'Waiting for RGS backend...';
}

String _clock(double? value) {
  if (value == null) {
    return '-- GHz';
  }
  return value >= 1000
      ? '${(value / 1000).toStringAsFixed(2)} GHz'
      : '${value.toStringAsFixed(0)} MHz';
}

String _memorySpeed(double? value) {
  return value == null ? '-- MHz' : '${value.toStringAsFixed(0)} MHz';
}

String _bytes(int? bytes) {
  if (bytes == null) {
    return '--';
  }

  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble().clamp(0, double.infinity);
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '${value.toStringAsFixed(0)} ${units[unit]}'
      : '${value.toStringAsFixed(1)} ${units[unit]}';
}

String _storageSubtitle(RgsStorageReading drive) {
  final subValue = _storageSubValue(drive);
  if (subValue.isNotEmpty) {
    return '${drive.name} $subValue';
  }

  return _storageSensorFallback(drive);
}

String _storageSubValue(RgsStorageReading drive) {
  if (drive.freeBytes != null && drive.totalBytes != null) {
    return '${_bytes(drive.freeBytes)} free of ${_bytes(drive.totalBytes)}';
  }

  return _storageSensorFallback(drive);
}

String _storageSensorFallback(RgsStorageReading drive) {
  return 'TEMP ${_temperature(drive.temperature)}  PWR ${_power(drive.power)}  ${_clock(drive.clock)}';
}

String _rate(double? bytesPerSecond) {
  return bytesPerSecond == null
      ? '--/s'
      : '${_bytes(bytesPerSecond.round())}/s';
}

bool _isNotGenericGpu(RgsGpuReading gpu) {
  final id = gpu.id.toLowerCase();
  final name = gpu.name.toLowerCase();
  if (id == 'gpu:default') {
    return false;
  }
  if (id.startsWith('gpu:pdh:') && RegExp(r'^gpu \d+$').hasMatch(name)) {
    return false;
  }
  return true;
}

String _time(DateTime value, bool useTwentyFourHour) {
  final hour = useTwentyFourHour
      ? value.hour.toString().padLeft(2, '0')
      : _twelveHour(value.hour).toString();
  final minute = value.minute.toString().padLeft(2, '0');
  final second = value.second.toString().padLeft(2, '0');
  if (useTwentyFourHour) {
    return '$hour:$minute:$second';
  }

  return '$hour:$minute:$second ${value.hour < 12 ? 'AM' : 'PM'}';
}

int _twelveHour(int hour) {
  final value = hour % 12;
  return value == 0 ? 12 : value;
}

String _date(DateTime value) {
  return '${_day(value)}, ${_month(value)} ${value.day}, ${value.year}';
}

String _shortDate(DateTime value) =>
    '${_month(value).substring(0, 3)} ${value.day}';

String _day(DateTime value) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return days[value.weekday - 1];
}

String _month(DateTime value) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return months[value.month - 1];
}
