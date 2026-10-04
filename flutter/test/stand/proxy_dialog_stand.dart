// A stand, not a test: draws the proxy dialog the way Windows draws it and
// writes down where its fields ended up, so a layout is judged by numbers and
// by a picture instead of by guessing from code. It is how the label-column
// defect was measured (the second field started 8.8 px to the right of the
// others, and "Пароль" sat 11.5 px below its field) and how the three ways of
// fixing it were compared.
//
// Run from flutter/ (the name does not end in _test, so `flutter test` alone
// skips it):
//   ARMDESK_STAND_OUT=/some/dir flutter test --update-goldens test/stand/proxy_dialog_stand.dart
//
// It needs the fonts of the platform it imitates: ARMDESK_STAND_FONTS points
// at a folder with segoeui.ttf, seguisb.ttf and segoeuib.ttf (under WSL that
// is /mnt/c/Windows/Fonts, the default). Without them it is skipped.
import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/form_text_field.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

final out =
    Platform.environment['ARMDESK_STAND_OUT'] ?? Directory.systemTemp.path;
final fonts =
    Platform.environment['ARMDESK_STAND_FONTS'] ?? '/mnt/c/Windows/Fonts';
// The icon font ships with the Flutter SDK that runs the stand.
final sdkFonts =
    '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File(f).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Widget label(String text) => Text(text);

/// The dialog body exactly as desktop_setting_page.dart builds it today.
Widget before(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 140),
            child: Align(
                alignment: Alignment.centerRight,
                child: Row(children: [
                  Text('Сервер').marginOnly(right: 4),
                  Icon(Icons.help_outline_outlined,
                      size: 16,
                      color: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.color
                          ?.withOpacity(0.5)),
                ])).marginOnly(right: 10),
          ),
          Expanded(child: TextField(key: const Key('f1'))),
        ]).marginOnly(bottom: 8),
        Row(children: [
          ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: Text('Имя пользователя:', textAlign: TextAlign.right)
                  .marginOnly(right: 10)),
          Expanded(child: TextField(key: const Key('f2'))),
        ]).marginOnly(bottom: 8),
        Row(children: [
          ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: Text('Пароль:', textAlign: TextAlign.right)
                  .marginOnly(right: 10)),
          Expanded(
              child: TextField(
                  key: const Key('f3'),
                  obscureText: true,
                  maxLength: 128,
                  decoration: InputDecoration(
                      suffixIcon: IconButton(
                          onPressed: () {},
                          icon: const Icon(Icons.visibility_off))))),
        ]),
      ],
    );

Widget eye() =>
    IconButton(onPressed: () {}, icon: const Icon(Icons.visibility_off));
Widget help(BuildContext context) => Icon(Icons.help_outline_outlined,
    size: 16,
    color: Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.5));

/// A: the label inside the field, as the mobile layout and the site do.
Widget variantA(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
                key: const Key('f1'),
                decoration: InputDecoration(
                    labelText: 'Сервер',
                    suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: help(context))))
            .marginOnly(bottom: 8),
        TextField(
                key: const Key('f2'),
                decoration:
                    const InputDecoration(labelText: 'Имя пользователя'))
            .marginOnly(bottom: 8),
        TextField(
            key: const Key('f3'),
            obscureText: true,
            maxLength: 128,
            decoration:
                InputDecoration(labelText: 'Пароль', suffixIcon: eye())),
      ],
    );

/// B: a label column as wide as its widest label, centred on the input box.
Widget variantB(BuildContext context) {
  Widget cell(Widget child) => SizedBox(
      height: 45, child: Align(alignment: Alignment.centerRight, child: child));
  return Table(
    columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
    defaultVerticalAlignment: TableCellVerticalAlignment.top,
    children: [
      TableRow(children: [
        cell(Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Сервер').marginOnly(right: 4),
          help(context),
        ])).marginOnly(right: 10, bottom: 8),
        const TextField(key: Key('f1')).marginOnly(bottom: 8),
      ]),
      TableRow(children: [
        cell(const Text('Имя пользователя')).marginOnly(right: 10, bottom: 8),
        const TextField(key: Key('f2')).marginOnly(bottom: 8),
      ]),
      TableRow(children: [
        cell(const Text('Пароль')).marginOnly(right: 10),
        TextField(
            key: const Key('f3'),
            obscureText: true,
            maxLength: 128,
            decoration: InputDecoration(suffixIcon: eye())),
      ]),
    ],
  );
}

/// C: the label above its field.
Widget variantC(BuildContext context) {
  final caption = Theme.of(context)
      .textTheme
      .bodySmall
      ?.copyWith(fontSize: 13, color: Colors.black54);
  Widget field(String text, Widget input, {Widget? trailing}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(text, style: caption),
            if (trailing != null) trailing.marginOnly(left: 4),
          ]).marginOnly(bottom: 4),
          input,
        ],
      );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      field('Сервер', const TextField(key: Key('f1')), trailing: help(context))
          .marginOnly(bottom: 12),
      field('Имя пользователя', const TextField(key: Key('f2')))
          .marginOnly(bottom: 12),
      field(
          'Пароль',
          TextField(
              key: const Key('f3'),
              obscureText: true,
              maxLength: 128,
              decoration: InputDecoration(suffixIcon: eye()))),
    ],
  );
}

/// A with values typed in: the labels float to the border.
Widget variantAFilled(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
                key: const Key('f1'),
                autofocus: true,
                controller: TextEditingController(
                    text: 'socks5://proxy.example.ru:1080'),
                decoration: InputDecoration(
                    labelText: 'Сервер',
                    suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: help(context))))
            .marginOnly(bottom: 8),
        TextField(
                key: const Key('f2'),
                controller: TextEditingController(text: 'oleg'),
                decoration:
                    const InputDecoration(labelText: 'Имя пользователя'))
            .marginOnly(bottom: 8),
        TextField(
            key: const Key('f3'),
            obscureText: true,
            maxLength: 128,
            controller: TextEditingController(text: 'secret123'),
            decoration:
                InputDecoration(labelText: 'Пароль', suffixIcon: eye())),
      ],
    );

/// The dialog body as it is built now: [FormTextField].
Widget after(BuildContext context, {bool filled = false}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormTextField(
          key: const Key('f1'),
          label: 'Сервер',
          controller: TextEditingController(
              text: filled ? 'socks5://proxy.example.ru:1080' : ''),
          tip: 'Подсказка',
          autofocus: filled,
        ).marginOnly(bottom: 8),
        FormTextField(
          key: const Key('f2'),
          label: 'Имя пользователя',
          controller: TextEditingController(text: filled ? 'oleg' : ''),
        ).marginOnly(bottom: 8),
        FormTextField(
          key: const Key('f3'),
          label: 'Пароль',
          controller: TextEditingController(text: filled ? 'secret123' : ''),
          isPassword: true,
          maxLength: 128,
        ),
      ],
    );

// Candidate for the theme pass, kept here until it is applied to every field.
/// A rounded outline whose label rises inside the field.
///
/// With [OutlineInputBorder] a floating label climbs onto the border and cuts
/// a gap in it. Reporting `isOutline == false` keeps the label inside, where
/// the forms on www.armilen.ru keep theirs, while the field still gets a
/// rounded frame and a rounded fill.
class FieldBorder extends InputBorder {
  const FieldBorder({
    super.borderSide = const BorderSide(),
    this.radius = 12,
  });

  final double radius;

  @override
  bool get isOutline => false;

  @override
  FieldBorder copyWith({BorderSide? borderSide, double? radius}) => FieldBorder(
      borderSide: borderSide ?? this.borderSide, radius: radius ?? this.radius);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  FieldBorder scale(double t) =>
      FieldBorder(borderSide: borderSide.scale(t), radius: radius * t);

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is FieldBorder
      ? FieldBorder(
          borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
          radius: lerpDouble(a.radius, radius, t)!)
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is FieldBorder
      ? FieldBorder(
          borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
          radius: lerpDouble(radius, b.radius, t)!)
      : super.lerpTo(b, t);

  RRect _shape(Rect rect) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect).deflate(borderSide.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(_shape(rect));

  @override
  void paint(Canvas canvas, Rect rect,
      {double? gapStart,
      double gapExtent = 0.0,
      double gapPercentage = 0.0,
      TextDirection? textDirection}) {
    if (borderSide.style == BorderStyle.none) return;
    canvas.drawRRect(
        _shape(rect).deflate(borderSide.width / 2), borderSide.toPaint());
  }

  @override
  bool operator ==(Object other) =>
      other is FieldBorder &&
      other.borderSide == borderSide &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(borderSide, radius);
}

Widget afterInside(BuildContext context) => Theme(
      data: Theme.of(context).copyWith(
          inputDecorationTheme: Theme.of(context)
              .inputDecorationTheme
              .copyWith(border: const FieldBorder(), isDense: false)),
      child: Builder(builder: (c) => after(c, filled: true)),
    );

Widget dialog(BuildContext context, Widget body) => AlertDialog(
      scrollable: true,
      title: const Text('SOCKS5/HTTP(S)-прокси'),
      content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 500), child: body)),
      actions: [
        OutlinedButton(
            key: const Key('cancel'),
            onPressed: () {},
            child: const Text('Отмена')),
        ElevatedButton(
            key: const Key('ok'),
            style: ElevatedButton.styleFrom(elevation: 0),
            onPressed: () {},
            child: const Text('OK')),
      ],
      titlePadding: MyTheme.dialogTitlePadding(),
      contentPadding: MyTheme.dialogContentPadding(actions: true),
      actionsPadding: MyTheme.dialogActionsPadding(),
      buttonPadding: MyTheme.dialogButtonPadding,
    );

void main() {
  final builders = <String, Widget Function(BuildContext)>{
    'before': before,
    'after': (c) => after(c),
    'after_filled': (c) => after(c, filled: true),
    'after_inside': afterInside,
    'a': variantA,
    'b': variantB,
    'c': variantC,
    'a_filled': variantAFilled,
  };
  final haveFonts = File('$fonts/segoeui.ttf').existsSync();
  for (final entry in builders.entries) {
    testWidgets(entry.key, skip: !haveFonts, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugDisableShadows = false;
      await tester.runAsync(() async {
        await loadFont('Segoe UI', [
          '$fonts/segoeui.ttf',
          '$fonts/seguisb.ttf',
          '$fonts/segoeuib.ttf'
        ]);
        await loadFont(
            'MaterialIcons', ['$sdkFonts/MaterialIcons-Regular.otf']);
      });
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1240, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MyTheme.lightTheme,
        home: Scaffold(
            backgroundColor: const Color(0xFFDDDDDD),
            body: Builder(
                builder: (c) => Center(child: dialog(c, entry.value(c))))),
      ));
      await tester.pumpAndSettle();

      String r(Finder f) {
        final b = tester.getRect(f);
        return 'left ${b.left.toStringAsFixed(1)} right ${b.right.toStringAsFixed(1)} top ${b.top.toStringAsFixed(1)} h ${b.height.toStringAsFixed(1)}';
      }

      Directory(out).createSync(recursive: true);
      final report = StringBuffer();
      for (final k in ['f1', 'f2', 'f3']) {
        report.writeln('field $k: ${r(find.byKey(Key(k)))}');
      }
      File('$out/${entry.key}.txt').writeAsStringSync(report.toString());
      await expectLater(
          find.byType(MaterialApp), matchesGoldenFile('$out/${entry.key}.png'));
      debugDisableShadows = true;
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
