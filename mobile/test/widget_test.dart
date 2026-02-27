import 'package:flutter_test/flutter_test.dart';

import 'package:svoyak_mobile/main.dart';

void main() {
  testWidgets('renders home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SvoyakApp());
    expect(find.text('Svoyak MVP Client'), findsOneWidget);
  });
}
