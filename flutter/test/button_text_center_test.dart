import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

Widget button(EdgeInsetsGeometry? padding) => MaterialApp(
      // The desktop theme: Material 2 at compact density.
      theme:
          ThemeData(useMaterial3: false, visualDensity: VisualDensity.compact),
      home: Scaffold(
        body: Center(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(padding: padding),
            onPressed: () {},
            child: const Text('OK'),
          ),
        ),
      ),
    );

void main() {
  // Segoe UI draws its capitals below the middle of the line box, so on
  // Windows a label centered by that box looked low in every button.
  testWidgets('on Windows a button lifts its label by a pixel, same height',
      (tester) async {
    await tester.pumpWidget(button(null));
    final plain = tester.getRect(find.byType(ElevatedButton));
    final plainLabel = tester.getCenter(find.text('OK'));

    await tester.pumpWidget(button(MyTheme.buttonPaddingFor(windows: true)));
    final lifted = tester.getRect(find.byType(ElevatedButton));
    final liftedLabel = tester.getCenter(find.text('OK'));

    expect(plainLabel.dy, plain.center.dy);
    expect(liftedLabel.dy, lifted.center.dy - 1);
    expect(lifted.height, plain.height);
  });

  test('other platforms keep the default padding', () {
    expect(MyTheme.buttonPaddingFor(windows: false), isNull);
  });
}
