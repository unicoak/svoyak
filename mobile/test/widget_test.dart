import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:svoyak_mobile/main.dart';

void main() {
  testWidgets('renders home screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const SvoyakApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('СИ: Онлайн'), findsAtLeastNWidgets(1));
  });
}
