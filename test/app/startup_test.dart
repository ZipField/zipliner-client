import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/app/startup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders while initialization is pending and then swaps to app', (
    tester,
  ) async {
    final pending = Completer<Widget>();
    var loads = 0;
    await tester.pumpWidget(
      ClientStartup(
        load: () {
          loads++;
          return pending.future;
        },
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(loads, 1, reason: 'loading starts after the first frame');

    pending.complete(const MaterialApp(home: Text('Ready')));
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows retry after initialization fails', (tester) async {
    final attempts = <Completer<Widget>>[];
    var loads = 0;
    final originalErrorHandler = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = originalErrorHandler);

    await tester.pumpWidget(
      ClientStartup(
        load: () {
          loads++;
          final request = Completer<Widget>();
          attempts.add(request);
          return request.future;
        },
      ),
    );
    await tester.pump();
    attempts.single.completeError(StateError('startup failed'));
    await tester.pumpAndSettle();
    expect(find.byType(TextButton), findsOneWidget);

    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(loads, 2);
    attempts.last.complete(const MaterialApp(home: Text('Recovered')));
    await tester.pumpAndSettle();
    expect(find.text('Recovered'), findsOneWidget);
  });
}
