// A stand, not a test: draws the dialog buttons with the fonts of each
// platform so the place of the text inside a button can be measured from the
// picture. A font's line box is not centered on its capital letters, so text
// that is geometrically centered looks low; by how much depends on the font.
//
// Run from flutter/:
//   ARMDESK_STAND_OUT=/some/dir flutter test --update-goldens test/stand/buttons_stand.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

final out =
    Platform.environment['ARMDESK_STAND_OUT'] ?? Directory.systemTemp.path;
final fonts =
    Platform.environment['ARMDESK_STAND_FONTS'] ?? '/mnt/c/Windows/Fonts';
final sdkFonts =
    '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader
        .addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
  }
  await loader.load();
}

const labels = ['OK', 'Отмена', 'Cancel', 'HH'];

void main() {
  // The theme is built once per process with the fonts of the platform it
  // sees then, so each platform is drawn by its own run:
  //   ARMDESK_STAND_PLATFORM=linux ... (Roboto, as on Linux and Android)
  final name = Platform.environment['ARMDESK_STAND_PLATFORM'] ?? 'windows';
  final platforms = {
    name: name == 'linux' ? TargetPlatform.linux : TargetPlatform.windows
  };
  for (final entry in platforms.entries) {
    testWidgets(entry.key, skip: !File('$fonts/segoeui.ttf').existsSync(),
        (tester) async {
      debugDefaultTargetPlatformOverride = entry.value;
      await tester.runAsync(() async {
        await loadFont('Segoe UI', [
          '$fonts/segoeui.ttf',
          '$fonts/seguisb.ttf',
          '$fonts/segoeuib.ttf'
        ]);
        await loadFont('Roboto', [
          '$sdkFonts/Roboto-Regular.ttf',
          '$sdkFonts/Roboto-Medium.ttf',
          '$sdkFonts/Roboto-Bold.ttf'
        ]);
      });
      tester.view.devicePixelRatio = 4;
      tester.view.physicalSize = const Size(3600, 480);
      addTearDown(tester.view.reset);

      // The host is never Windows, so the correction is applied by hand.
      final padding = MyTheme.buttonPaddingFor(windows: entry.key == 'windows');
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MyTheme.lightTheme,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final text in labels) ...[
                OutlinedButton(
                    key: Key('o-$text'),
                    style: OutlinedButton.styleFrom(padding: padding),
                    onPressed: () {},
                    child: Text(text)),
                const SizedBox(width: 12),
                ElevatedButton(
                    key: Key('e-$text'),
                    style: ElevatedButton.styleFrom(
                        elevation: 0, padding: padding),
                    onPressed: () {},
                    child: Text(text)),
                const SizedBox(width: 12),
              ]
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      Directory(out).createSync(recursive: true);
      final report = StringBuffer();
      for (final text in labels) {
        for (final kind in ['o', 'e']) {
          final b = tester.getRect(find.byKey(Key('$kind-$text')));
          report.writeln(
              '$kind\t$text\t${b.left}\t${b.top}\t${b.right}\t${b.bottom}');
        }
      }
      File('$out/buttons_${entry.key}.txt')
          .writeAsStringSync(report.toString());
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('$out/buttons_${entry.key}.png'));
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
