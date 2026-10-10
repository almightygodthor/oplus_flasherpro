import 'package:flasherpro/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the three primary utilities', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FlasherProApp());

    expect(find.text('Platform Tools'), findsOneWidget);
    expect(find.text('Firmware Unpacker'), findsOneWidget);
    expect(find.text('Firmware Flasher'), findsOneWidget);
    expect(find.text('FLASHERPRO'), findsOneWidget);
  });
}
