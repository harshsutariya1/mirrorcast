import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast/src/sender/ui/pairing_screens.dart';

void main() {
  testWidgets('PinField shows digits and completes after six', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    String? completed;
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinField(controller: controller, focusNode: focusNode, onCompleted: (pin) => completed = pin),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '48a29');
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    expect(find.text('a'), findsNothing, reason: 'only digits are accepted');
    expect(completed, isNull);

    await tester.enterText(find.byType(TextField), '4829136');
    await tester.pump();
    expect(controller.text, '482913', reason: 'limited to six digits');
    expect(completed, '482913');
  });
}
