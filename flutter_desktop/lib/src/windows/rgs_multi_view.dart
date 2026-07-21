import 'dart:async';

import 'package:flutter/services.dart';

final class RgsViewBounds {
  const RgsViewBounds({
    required this.position,
    required this.size,
    required this.physicalPosition,
    required this.scaleFactor,
  });

  factory RgsViewBounds.fromMap(Map<Object?, Object?> map) {
    double number(String key, [double fallback = 0]) =>
        (map[key] as num?)?.toDouble() ?? fallback;
    return RgsViewBounds(
      position: Offset(number('left'), number('top')),
      size: Size(number('width'), number('height')),
      physicalPosition: Offset(number('physicalLeft'), number('physicalTop')),
      scaleFactor: number('scaleFactor', 1),
    );
  }

  final Offset position;
  final Size size;
  final Offset physicalPosition;
  final double scaleFactor;
}

final class RgsViewEvent {
  const RgsViewEvent({
    required this.name,
    required this.viewId,
    required this.bounds,
  });

  factory RgsViewEvent.fromMap(Map<Object?, Object?> map) => RgsViewEvent(
        name: map['name']?.toString() ?? '',
        viewId: (map['viewId'] as num).toInt(),
        bounds: RgsViewBounds.fromMap(map),
      );

  final String name;
  final int viewId;
  final RgsViewBounds bounds;
}

final class RgsMultiView {
  RgsMultiView._();

  static const MethodChannel _channel =
      MethodChannel('studio.rahngaming.rgs_sensor_panel/multi_view');
  static final StreamController<RgsViewEvent> _events =
      StreamController<RgsViewEvent>.broadcast();

  static Stream<RgsViewEvent> get events => _events.stream;

  static void initialize() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        _events.add(
          RgsViewEvent.fromMap(
            Map<Object?, Object?>.from(call.arguments as Map),
          ),
        );
      }
    });
  }

  static Future<int> mainViewId() async =>
      await _channel.invokeMethod<int>('mainViewId') ?? 0;

  static Future<void> configureMain({required bool startHidden}) =>
      _channel.invokeMethod<void>(
        'configureMain',
        {'startHidden': startHidden},
      );

  static Future<void> quit() => _channel.invokeMethod<void>('quit');

  static Future<int> create({
    required String title,
    required Size size,
    Offset? physicalPosition,
  }) async {
    final id = await _channel.invokeMethod<int>('create', {
      'title': title,
      'width': size.width,
      'height': size.height,
      'hasPosition': physicalPosition != null,
      'physicalLeft': physicalPosition?.dx ?? 0,
      'physicalTop': physicalPosition?.dy ?? 0,
    });
    if (id == null) throw StateError('The native view was not created.');
    return id;
  }

  static Future<void> destroy(int viewId) => _call('destroy', viewId);
  static Future<void> show(int viewId) => _call('show', viewId);
  static Future<void> hide(int viewId) => _call('hide', viewId);
  static Future<void> focus(int viewId) => _call('focus', viewId);
  static Future<void> startDragging(int viewId) =>
      _call('startDragging', viewId);
  static Future<void> startResizing(int viewId, String edge) =>
      _call('startResizing', viewId, {'edge': edge});
  static Future<void> setAlwaysOnTop(int viewId, bool value) =>
      _call('setAlwaysOnTop', viewId, {'value': value});
  static Future<void> setOpacity(int viewId, double value) =>
      _call('setOpacity', viewId, {'value': value});
  static Future<void> setSkipTaskbar(int viewId, bool value) =>
      _call('setSkipTaskbar', viewId, {'value': value});
  static Future<void> setSize(int viewId, Size size) => _call(
        'setSize',
        viewId,
        {'width': size.width, 'height': size.height},
      );
  static Future<void> setPhysicalPosition(int viewId, Offset position) => _call(
        'setPosition',
        viewId,
        {'physicalLeft': position.dx, 'physicalTop': position.dy},
      );

  static Future<RgsViewBounds> getBounds(int viewId) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'getBounds',
      {'viewId': viewId},
    );
    if (map == null) throw StateError('The native view no longer exists.');
    return RgsViewBounds.fromMap(map);
  }

  static Future<void> _call(
    String method,
    int viewId, [
    Map<String, Object?> extra = const {},
  ]) =>
      _channel.invokeMethod<void>(method, {'viewId': viewId, ...extra});
}
