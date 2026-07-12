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
    final height = RgsPanelSettings._asDouble(value['Height'] ?? value['height']);
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

      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        return firstLaunchDefaults();
      }

      final defaults = firstLaunchDefaults();
      final hiddenIds = decoded.containsKey('HiddenDeviceIds')
          ? _readStringSet(decoded['HiddenDeviceIds'])
          : defaults.hiddenIds;
      return RgsPanelSettings(
        hiddenIds: hiddenIds,
        widgetPositions: decoded.containsKey('WidgetPositions')
            ? _readWidgetPositions(decoded['WidgetPositions'])
            : defaults.widgetPositions,
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
