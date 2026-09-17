import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';
import 'package:lib_pdf/src/core/deflate.dart';
import 'package:lib_pdf/src/font/ttf_parser.dart';
import 'package:lib_pdf/src/font/ttf_subset.dart';
import 'package:lib_pdf/src/layout/break_finder.dart';

import 'support/grafico_barras.dart';

/// Extrai e descomprime os content streams das páginas (formato gerado pela lib).
List<String> _pageContents(List<int> pdf) {
  final text = String.fromCharCodes(pdf);
  final result = <String>[];
  final pageRefs = RegExp(
    r'/Type /Page/Parent \d+ 0 R/MediaBox \[[^\]]*\]/Resources <<.*?>>/Contents (\d+) 0 R',
  ).allMatches(text.replaceAll('\n', ' ')).map((m) => int.parse(m.group(1)!));
  for (final id in pageRefs) {
    final start = text.indexOf('\n$id 0 obj\n');
    final streamStart = text.indexOf('stream\n', start) + 7;
    final dict = text.substring(start, streamStart);
    final length = int.parse(RegExp(r'/Length (\d+)').firstMatch(dict)!.group(1)!);
    var data = pdf.sublist(streamStart, streamStart + length);
    if (dict.contains('FlateDecode')) data = ZLib.decode(data);
    result.add(String.fromCharCodes(data));
  }
  return result;
}

Future<List<int>> _render(WidgetTester tester, Widget child) async {
  final doc = PdfDocument()..addPage(PdfPage(build: (ctx) => child));
  return (await tester.runAsync(doc.save))!;
}

void main() {
  testWidgets('pontos de quebra: entre filhos e entre linhas, nunca dentro de atômicos', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            child: Column(
              key: key,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 50),
                const Text('linha um linha dois linha três linha quatro', style: TextStyle(fontSize: 20)),
                Row(children: const [SizedBox(width: 50, height: 40), SizedBox(width: 50, height: 60)]),
                const PdfKeepTogether(child: Column(children: [SizedBox(height: 30), SizedBox(height: 30)])),
                const PdfPageBreak(),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
    final root = key.currentContext!.findRenderObject()! as RenderBox;
    final analysis = BreakAnalysis.of(root);

    expect(analysis.breaks, contains(50));
    // Linhas do texto (fonte de teste: 20 px por linha).
    final textHeight = tester.getSize(find.byType(Text)).height;
    expect(textHeight, greaterThan(40));
    expect(analysis.breaks.where((y) => y > 50 && y < 50 + textHeight), isNotEmpty);
    // Dentro da Row, o filho de 60 px impede cortes entre 40 e 60.
    final rowTop = 50 + textHeight;
    expect(analysis.breaks.any((y) => y > rowTop + 0.5 && y < rowTop + 59.5), isFalse);
    // O PdfKeepTogether não tem cortes internos.
    final keepTop = rowTop + 60;
    expect(analysis.breaks.any((y) => y > keepTop + 0.5 && y < keepTop + 59.5), isFalse);
    expect(analysis.forcedBreaks, [keepTop + 60]);
  });

  testWidgets('CustomPainter vira vetor; só os rótulos do TextPainter viram imagem', (tester) async {
    final pdf = await _render(
      tester,
      const SizedBox(width: 400, height: 240, child: GraficoBarras(dados: {'A': 1, 'B': 2, 'C': 3})),
    );
    final content = _pageContents(pdf).single;
    // Barras com cantos arredondados (curvas) e linhas de grade.
    expect(RegExp(r' c\n').allMatches(content).length, greaterThan(6));
    expect(RegExp(r'^S$', multiLine: true).allMatches(content).length, greaterThanOrEqualTo(5));
    // 5 valores de grade + 3 valores + 3 rótulos.
    expect(RegExp(r'/Im\d+ Do').allMatches(content).length, 11);
  });

  testWidgets('efeitos sem equivalente vetorial viram imagem da subárvore', (tester) async {
    final pdf = await _render(
      tester,
      Center(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
          child: Container(width: 100, height: 100, color: Colors.red),
        ),
      ),
    );
    final content = _pageContents(pdf).single;
    expect(RegExp(r'/Im\d+ Do').allMatches(content).length, 1);
    expect(content, isNot(contains(' re\n.9569')));
  });

  test('subset TrueType mantém só os glifos usados e continua legível', () {
    final font = TtfFont(File('fonts/Roboto-Regular.ttf').readAsBytesSync());
    final a = font.glyphForCodePoint('a'.codeUnitAt(0));
    final cedilha = font.glyphForCodePoint('ç'.codeUnitAt(0));
    final z = font.glyphForCodePoint('z'.codeUnitAt(0));
    final subset = subsetTrueType(font, {a, cedilha});
    expect(subset.length, lessThan(font.bytes.length ~/ 10));

    final parsed = TtfFont(subset);
    expect(parsed.numGlyphs, font.numGlyphs);
    expect(parsed.glyphRange(a).length, font.glyphRange(a).length + (4 - font.glyphRange(a).length % 4) % 4);
    expect(parsed.glyphRange(z).length, 0);
    // "ç" é composto: seus componentes precisam ter sido mantidos.
    for (final component in font.compositeComponents(cedilha)) {
      expect(parsed.glyphRange(component).length, greaterThan(0));
    }
  });
}
