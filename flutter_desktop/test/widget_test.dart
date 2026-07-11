import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rgs_sensor_panel_flutter/main.dart';

void main() {
  void useLargeSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(520, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  testWidgets('control panel renders', (WidgetTester tester) async {
    useLargeSurface(tester);

    await tester.pumpWidget(
      const RgsSensorPanelApp(widgetKind: null, pollSensors: false),
    );

    expect(find.text('RGS SENSOR PANEL'), findsOneWidget);
    expect(find.text('Widget opacity'), findsOneWidget);
    expect(find.text('WIDGETS'), findsOneWidget);
    expect(find.text('Use 24-hour time'), findsNothing);
  });

  testWidgets('widget window renders cpu view', (WidgetTester tester) async {
    useLargeSurface(tester);

    await tester.pumpWidget(
      const RgsSensorPanelApp(
        widgetKind: RgsWidgetKind.cpu,
        pollSensors: false,
      ),
    );

    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('Loading sensors'), findsOneWidget);
  });
}
