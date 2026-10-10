import 'package:flasherpro/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the three primary utilities', (tester) async {
    await tester.pumpWidget(const FlasherProApp());

    expect(find.text('Platform Tools'), findsOneWidget);
    expect(find.text('Firmware Unpacker'), findsOneWidget);
    expect(find.text('Firmware Flasher'), findsOneWidget);
    expect(find.text('FLASHERPRO'), findsOneWidget);
  });
}
