import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neurobridge/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Profile setup requires both names and consent', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: CareBoard()));
    await tester.pumpAndSettle();
    expect(find.text('I need water'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Set up'));
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(FilledButton, 'Create profile');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(find.byType(TextField).first, 'Alex');
    await tester.enterText(find.byType(TextField).last, 'Sam');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
