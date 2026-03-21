import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

void main() {
  testWidgets('shell app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const FreeloomShellApp());

    expect(find.textContaining('Freeloom'), findsWidgets);
  });
}
