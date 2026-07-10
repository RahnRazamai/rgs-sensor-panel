import 'dart:convert';
import 'dart:io';

final class RgsPanelSettings {
  RgsPanelSettings({
    required Set<String> hiddenIds,
    required this.useTwentyFourHourClock,
    required this.minimizeToTrayOnClose,
    required this.alwaysOnTop,
    required this.showSupportPanel,
    required this.autoLaunchOnBoot,
    required double widgetOpacity,
  })  : hiddenIds = hiddenIds.map(_normalizeId).toSet(),
        widgetOpacity = _clampOpacity(widgetOpacity);

  static const cpuWidgetId = 'widget:cpu';
  static const ramWidgetId = 'widget:ram';
  static const gpuWidgetId = 'widget:gpu';
  static const storageWidgetId = 'widget:storage';
  static const clockWidgetId = 'widget:clock';

  final Set<String> hiddenIds;
  bool useTwentyFourHourClock;
  bool minimizeToTrayOnClose;
  bool alwaysOnTop;
  bool showSupportPanel;
  bool autoLaunchOnBoot;
  double widgetOpacity;

  static RgsPanelSettings firstLaunchDefaults() {
    return RgsPanelSettings(
      hiddenIds: {
        cpuWidgetId,
        ramWidgetId,
        gpuWidgetId,
        storageWidgetId,
        clockWidgetId,
      },
      useTwentyFourHourClock: true,
      minimizeToTrayOnClose: true,
      alwaysOnTop: true,
      showSupportPanel: true,
      autoLaunchOnBoot: false,
      widgetOpacity: 0.95,
    );
  }

  static RgsPanelSettings load() {
    try {
      final file = File(settingsPath);
      if (!file.existsSync()) {
        return firstLaunchDefaults();
      }

      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        return firstLaunchDefaults();
      }

      final defaults = firstLaunchDefaults();
      return RgsPanelSettings(
        hiddenIds: _readStringSet(decoded['HiddenDeviceIds']),
        useTwentyFourHourClock:
            decoded['UseTwentyFourHourClock'] as bool? ?? defaults.useTwentyFourHourClock,
        minimizeToTrayOnClose:
            decoded['MinimizeToTrayOnClose'] as bool? ?? defaults.minimizeToTrayOnClose,
        alwaysOnTop: decoded['AlwaysOnTop'] as bool? ?? defaults.alwaysOnTop,
        showSupportPanel:
            decoded['ShowSupportPanel'] as bool? ?? defaults.showSupportPanel,
        autoLaunchOnBoot:
            decoded['AutoLaunchOnBoot'] as bool? ?? defaults.autoLaunchOnBoot,
        widgetOpacity:
            _asDouble(decoded['WidgetOpacity']) ?? defaults.widgetOpacity,
      );
    } on Object {
      return firstLaunchDefaults();
    }
  }

  static String get settingsPath {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.trim().isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return '$base\\RahnGamingStudio\\SensorPanel\\device-visibility.json';
  }

  bool isVisible(String id) => !hiddenIds.contains(_normalizeId(id));

  void setVisible(String id, bool isVisible) {
    final normalized = _normalizeId(id);
    if (isVisible) {
      hiddenIds.remove(normalized);
    } else {
      hiddenIds.add(normalized);
    }
  }

  void showAll() {
    hiddenIds.clear();
  }

  void save() {
    try {
      final file = File(settingsPath);
      file.parent.createSync(recursive: true);
      final sortedHiddenIds = hiddenIds.toList()
        ..sort((a, b) => a.compareTo(b));
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'HiddenDeviceIds': sortedHiddenIds,
          'UseTwentyFourHourClock': useTwentyFourHourClock,
          'MinimizeToTrayOnClose': minimizeToTrayOnClose,
          'AlwaysOnTop': alwaysOnTop,
          'ShowSupportPanel': showSupportPanel,
          'AutoLaunchOnBoot': autoLaunchOnBoot,
          'WidgetOpacity': widgetOpacity,
        }),
      );
    } on Object {
      // Preferences should never stop the widgets from rendering.
    }
  }

  static Set<String> _readStringSet(Object? value) {
    if (value is! List) {
      return {};
    }

    return value
        .whereType<Object>()
        .map((item) => _normalizeId(item.toString()))
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  static String _normalizeId(String id) => id.trim().toLowerCase();

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static double _clampOpacity(double value) {
    if (value < 0.35) {
      return 0.35;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }
}
