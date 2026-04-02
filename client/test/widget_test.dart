import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:client/main.dart';

void main() {
  testWidgets('shell app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: SirixShellApp()));

    expect(find.byType(SirixShellApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
