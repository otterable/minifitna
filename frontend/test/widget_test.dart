// test/widget_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// NOTE: Import must match your pubspec `name:`.
// Your logs show: packages/run_weight_coach/main.dart
import 'package:run_weight_coach/main.dart';

void main() {
  testWidgets('Auth screen renders title and fields', (WidgetTester tester) async {
    // Build the app
    await tester.pumpWidget(const MyApp());

    // Let async boot (SharedPreferences/http try-catch) settle a bit
    await tester.pump(const Duration(milliseconds: 300));

    // Expect the app title on the Auth screen
    expect(find.text('Run & Weight Coach'), findsOneWidget);

    // Username and Password fields present
    expect(find.byIcon(Icons.person), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);

    // Buttons exist
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Register'), findsOneWidget);
  });
}
