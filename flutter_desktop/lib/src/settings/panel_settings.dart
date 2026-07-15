import 'dart:convert';
import 'dart:io';

final class RgsWidgetPosition {
  const RgsWidgetPosition({
    required this.left,
    required this.top,
    this.width,
    this.height,
    this.physicalLeft,
    this.physicalTop,
    this.scaleFactor,
  });

  final double left;
  final double top;
  final double? width;
  final double? height;
  final double? physicalLeft;
  final double? physicalTop;
  final double? scaleFactor;

  Map<String, double> toJson() {
    final json = {
      'Left': left,
      'Top': top,
    };
    if (width != null) {
      json['Width'] = width!;
    }
    if (height != null) {
      json['Height'] = height!;
    }
    if (physicalLeft != null) {
      json['PhysicalLeft'] = physicalLeft!;
    }
    if (physicalTop != null) {
      json['PhysicalTop'] = physicalTop!;
    }
    if (scaleFactor != null) {
      json['ScaleFactor'] = scaleFactor!;
    }
    return json;
  }

  static RgsWidgetPosition? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }

    final left = RgsPanelSettings._asDouble(value['Left'] ?? value['left']);
    final top = RgsPanelSettings._asDouble(value['Top'] ?? value['top']);
    final width = RgsPanelSettings._asDouble(value['Width'] ?? value['width']);
    final height =
        RgsPanelSettings._asDouble(value['Height'] ?? value['height']);
    final physicalLeft = RgsPanelSettings._asDouble(
      value['PhysicalLeft'] ?? value['physicalLeft'],
    );
    final physicalTop = RgsPanelSettings._asDouble(
      value['PhysicalTop'] ?? value['physicalTop'],
    );
    final scaleFactor = RgsPanelSettings._asDouble(
      value['ScaleFactor'] ?? value['scaleFactor'],
    );
    if (left == null || top == null) {
      return null;
    }

    return RgsWidgetPosition(
      left: left,
      top: top,
      width: width,
      height: height,
      physicalLeft: physicalLeft,
      physicalTop: physicalTop,
      scaleFactor: scaleFactor,
    );
  }
}

final class RgsPanelSettings {
  RgsPanelSettings({
    required Set<String> hiddenIds,
    required Map<String, RgsWidgetPosition> widgetPositions,
    required this.useTwentyFourHourClock,
    required this.minimizeToTrayOnClose,
    required this.alwaysOnTop,
    required this.showSupportPanel,
    required this.autoLaunchOnBoot,
    required double widgetOpacity,
  })  : hiddenIds = hiddenIds.map(_normalizeId).toSet(),
        widgetPositions = {
          for (final entry in widgetPositions.entries)
            _normalizeId(entry.key): entry.value,
        },
        widgetOpacity = _clampOpacity(widgetOpacity);

  static const cpuWidgetId = 'widget:cpu';
  static const ramWidgetId = 'widget:ram';
  static const gpuWidgetId = 'widget:gpu';
  static const storageWidgetId = 'widget:storage';
  static const clockWidgetId = 'widget:clock';
  static const musicWidgetId = 'widget:music';
  static const _currentSettingsVersion = 2;

  final Set<String> hiddenIds;
  final Map<String, RgsWidgetPosition> widgetPositions;
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
        musicWidgetId,
      },
      widgetPositions: const {},
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

      return fromJson(jsonDecode(file.readAsStringSync()));
    } on Object {
      return firstLaunchDefaults();
    }
  }

  static RgsPanelSettings fromJson(Object? value) {
    if (value is! Map) {
      return firstLaunchDefaults();
    }

    final defaults = firstLaunchDefaults();
    final hiddenIds = value.containsKey('HiddenDeviceIds')
        ? _readStringSet(value['HiddenDeviceIds'])
        : defaults.hiddenIds;
    final settingsVersion = _asInt(value['SettingsVersion']) ?? 1;
    if (settingsVersion < _currentSettingsVersion) {
      // New widget IDs must be opted in on upgrade; otherwise the negative
      // visibility list would open them automatically for existing users.
      hiddenIds.add(musicWidgetId);
    }

    return RgsPanelSettings(
      hiddenIds: hiddenIds,
      widgetPositions: value.containsKey('WidgetPositions')
          ? _readWidgetPositions(value['WidgetPositions'])
          : defaults.widgetPositions,
      useTwentyFourHourClock: value['UseTwentyFourHourClock'] as bool? ??
          defaults.useTwentyFourHourClock,
      minimizeToTrayOnClose: value['MinimizeToTrayOnClose'] as bool? ??
          defaults.minimizeToTrayOnClose,
      alwaysOnTop: value['AlwaysOnTop'] as bool? ?? defaults.alwaysOnTop,
      showSupportPanel:
          value['ShowSupportPanel'] as bool? ?? defaults.showSupportPanel,
      autoLaunchOnBoot:
          value['AutoLaunchOnBoot'] as bool? ?? defaults.autoLaunchOnBoot,
      widgetOpacity:
          _asDouble(value['WidgetOpacity']) ?? defaults.widgetOpacity,
    );
  }

  static String get settingsPath {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.trim().isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return '$base\\RahnGamingStudio\\SensorPanel\\device-visibility.json';
  }

  bool isVisible(String id) => !hiddenIds.contains(_normalizeId(id));

  RgsWidgetPosition? widgetPosition(String id) {
    return widgetPositions[_normalizeId(id)];
  }

  void setWidgetPosition(
    String id,
    double left,
    double top, {
    double? width,
    double? height,
    double? physicalLeft,
    double? physicalTop,
    double? scaleFactor,
  }) {
    widgetPositions[_normalizeId(id)] = RgsWidgetPosition(
      left: left,
      top: top,
      width: width,
      height: height,
      physicalLeft: physicalLeft,
      physicalTop: physicalTop,
      scaleFactor: scaleFactor,
    );
  }

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
      final sortedWidgetPositionKeys = widgetPositions.keys.toList()
        ..sort((a, b) => a.compareTo(b));
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'SettingsVersion': _currentSettingsVersion,
          'HiddenDeviceIds': sortedHiddenIds,
          'WidgetPositions': {
            for (final key in sortedWidgetPositionKeys)
              key: widgetPositions[key]?.toJson(),
          },
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

  static Map<String, RgsWidgetPosition> _readWidgetPositions(Object? value) {
    if (value is! Map) {
      return {};
    }

    final positions = <String, RgsWidgetPosition>{};
    for (final entry in value.entries) {
      final key = _normalizeId(entry.key.toString());
      final position = RgsWidgetPosition.fromJson(entry.value);
      if (key.isNotEmpty && position != null) {
        positions[key] = position;
      }
    }
    return positions;
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

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value);
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
