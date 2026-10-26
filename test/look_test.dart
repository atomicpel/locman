import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:locman/state.dart';
import 'package:locman/ui/backdrop.dart';
import 'package:locman/ui/orb.dart';
import 'package:locman/ui/theme.dart';

/// Снимки обликов (фон + кнопка) в build/look — для просмотра в отчёте сборки.
void main() {
  testWidgets('облики рисуются', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    Directory('build/look').createSync(recursive: true);
    for (final skin in Skin.values) {
      for (final dark in [true, false]) {
        final lock = skinMeta[skin]!.$3;
        if (lock != null && lock != (dark ? 'dark' : 'light')) continue;
        final p = Palette.of(skin, dark);
        for (final phase in [Phase.off, Phase.on]) {
          final key = GlobalKey();
          await tester.pumpWidget(
            MediaQuery(
              data: const MediaQueryData(size: Size(360, 640), disableAnimations: true),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: PaletteScope(
                  palette: p,
                  child: RepaintBoundary(
                    key: key,
                    child: SizedBox(
                      width: 360,
                      height: 640,
                      child: Stack(
                        children: [
                          Positioned.fill(child: CustomPaint(painter: BackdropPainter(p, 0.27, on: phase == Phase.on))),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 100,
                            child: Center(child: Orb(phase: phase, onTap: () {}, live: false)),
                          ),
                          Positioned(
                            left: 16,
                            right: 16,
                            top: 360,
                            child: Container(
                              height: 90,
                              decoration: BoxDecoration(
                                color: p.surface,
                                borderRadius: BorderRadius.circular(p.rCard),
                                border: Border.all(color: p.border),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await tester.runAsync(() async {
            final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final img = await ro.toImage(pixelRatio: 1);
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            File('build/look/${skin.name}-${dark ? 'dark' : 'light'}-${phase.name}.png')
                .writeAsBytesSync(data!.buffer.asUint8List());
          });
        }
      }
    }
    expect(Directory('build/look').listSync().length, greaterThan(10));
  });
}
