import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rgs_sensor_panel_flutter/main.dart';
import 'package:rgs_sensor_panel_flutter/src/settings/panel_settings.dart';

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
    expect(find.text('Widget text size'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final textSizeSlider = find.byWidgetPredicate(
      (widget) =>
          widget is Slider &&
          widget.max == RgsPanelSettings.maximumWidgetTextScale,
    );
    expect(textSizeSlider, findsOneWidget);
    await tester.drag(textSizeSlider, const Offset(500, 0));
    await tester.pump();
    expect(
      tester.widget<Slider>(textSizeSlider).value,
      RgsPanelSettings.maximumWidgetTextScale,
    );
    expect(find.text('150%'), findsOneWidget);
    expect(find.text('WIDGETS'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Music player'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Music player'), findsOneWidget);
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

  testWidgets('widget window renders music view without sensors', (
    WidgetTester tester,
  ) async {
    useLargeSurface(tester);

    await tester.pumpWidget(
      const RgsSensorPanelApp(
        widgetKind: RgsWidgetKind.music,
        pollSensors: false,
      ),
    );

    expect(find.text('MUSIC'), findsOneWidget);
    expect(find.text('Finding media'), findsOneWidget);
    expect(find.text('Loading sensors'), findsNothing);
  });
}
