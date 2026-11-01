import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast/src/shared/widgets.dart';

void main() {
  testWidgets('AppLogo loads the bundled logo asset', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Center(child: AppLogo(size: 64))));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('MirrorCast logo'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'assets/brand/logo.png must be declared and present');
  });
}
