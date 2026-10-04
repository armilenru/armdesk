import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/widgets/form_text_field.dart';
import 'package:flutter_test/flutter_test.dart';

Widget form({required bool desktop, bool enabled = true}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          child: Column(children: [
            FormTextField(
              key: const Key('short'),
              label: 'ID',
              controller: TextEditingController(),
              tip: 'where the proxy lives',
              enabled: enabled,
              desktop: desktop,
            ),
            FormTextField(
              key: const Key('long'),
              label: 'Имя пользователя для подключения',
              controller: TextEditingController(),
              desktop: desktop,
            ),
            FormTextField(
              key: const Key('password'),
              label: 'Пароль',
              controller: TextEditingController(text: 'secret'),
              isPassword: true,
              maxLength: 128,
              desktop: desktop,
            ),
          ]),
        ),
      ),
    );

void main() {
  // The label column these fields replace gave each field its own left edge:
  // the longer the label, the further right its field began.
  testWidgets('fields of one form start and end together, whatever the label',
      (tester) async {
    await tester.pumpWidget(form(desktop: true));
    final rects = ['short', 'long', 'password']
        .map((key) => tester.getRect(find.byKey(Key(key))))
        .toList();

    expect(rects.map((r) => r.left).toSet(), hasLength(1));
    expect(rects.map((r) => r.right).toSet(), hasLength(1));
    expect(rects.first.width, 500);
  });

  testWidgets('the password stays hidden until the eye is pressed',
      (tester) async {
    await tester.pumpWidget(form(desktop: true));
    bool hidden() => tester
        .widget<TextField>(find.descendant(
            of: find.byKey(const Key('password')),
            matching: find.byType(TextField)))
        .obscureText;

    expect(hidden(), isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(hidden(), isFalse);
  });

  testWidgets('the tip is an icon on the desktop and a line on a phone',
      (tester) async {
    await tester.pumpWidget(form(desktop: true));
    expect(find.byIcon(Icons.help_outline_outlined), findsOneWidget);
    expect(find.text('where the proxy lives'), findsNothing);

    await tester.pumpWidget(form(desktop: false));
    expect(find.byIcon(Icons.help_outline_outlined), findsNothing);
    expect(find.text('where the proxy lives'), findsOneWidget);
  });

  testWidgets('a field told to be disabled is', (tester) async {
    await tester.pumpWidget(form(desktop: true, enabled: false));
    final field = tester.widget<TextField>(find.descendant(
        of: find.byKey(const Key('short')), matching: find.byType(TextField)));

    expect(field.enabled, isFalse);
  });

  testWidgets('a required field marks its label, an optional one does not',
      (tester) async {
    Widget one({required bool isRequired}) => MaterialApp(
          home: Scaffold(
              body: FormTextField(
            label: 'ID',
            isRequired: isRequired,
            controller: TextEditingController(),
            desktop: true,
          )),
        );

    await tester.pumpWidget(one(isRequired: true));
    expect(find.text('ID *', findRichText: true), findsOneWidget);

    await tester.pumpWidget(one(isRequired: false));
    expect(find.text('ID *', findRichText: true), findsNothing);
    expect(find.text('ID'), findsOneWidget);
  });

  testWidgets('what the dialog asks of the input reaches the text field',
      (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: FormTextField(
        label: 'Port',
        hintText: '3389',
        controller: controller,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        desktop: true,
      )),
    ));

    await tester.enterText(find.byType(TextField), 'a33b89');
    expect(controller.text, '3389');
    expect(
        tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
        '3389');
  });
}
