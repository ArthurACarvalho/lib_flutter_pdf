import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf_example/relatorio_vendas.dart';

void main() {
  testWidgets('gera o relatório de vendas com fl_chart', (tester) async {
    await tester.runAsync(() async {
      // Nos testes as fontes do app não são carregadas automaticamente.
      final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    debugDisableShadows = false;
    final watch = Stopwatch()..start();
    final bytes = (await tester.runAsync(gerarRelatorioVendas))!;
    debugDisableShadows = true;
    debugPrint('relatório: ${bytes.length} bytes em ${watch.elapsedMilliseconds} ms');
    Directory('build').createSync(recursive: true);
    File('build/relatorio_vendas.pdf').writeAsBytesSync(bytes);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
