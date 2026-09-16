import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

/// Simula o `printing`: lê os tamanhos das páginas do PDF e devolve imagens lisas.
class _FakeBackend extends PdfViewerBackend {
  final rasterRequests = <({List<int>? pages, double dpi})>[];
  int printCalls = 0;

  @override
  Stream<ui.Image> rasterize(Uint8List pdf, {List<int>? pages, required double dpi}) async* {
    rasterRequests.add((pages: pages, dpi: dpi));
    final sizes = [
      for (final m in RegExp(r'/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]').allMatches(String.fromCharCodes(pdf)))
        (double.parse(m.group(1)!), double.parse(m.group(2)!)),
    ];
    for (final index in pages ?? List.generate(sizes.length, (i) => i)) {
      final (w, h) = sizes[index];
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFFEEEEEE), BlendMode.src);
      yield recorder.endRecording().toImageSync((w * dpi / 72).round(), (h * dpi / 72).round());
    }
  }

  @override
  Future<bool> printPdf(Uint8List pdf, {required String name}) async {
    printCalls++;
    return true;
  }
}

PdfDocument _document() => PdfDocument()
  ..addPage(PdfMultiPage(
    build: (ctx) => const [Text('Página um'), PdfPageBreak(), Text('Página dois'), PdfPageBreak(), Text('Página três')],
  ));

void main() {
  testWidgets('navega, dá zoom e imprime', (tester) async {
    final bytes = (await tester.runAsync(_document().save))!;
    final backend = _FakeBackend();
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PdfDocumentViewer.bytes(bytes, backend: backend)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final page = find.byKey(const ValueKey('lib_pdf_page_0'));
    final fitWidth = tester.getSize(page).width;
    expect(fitWidth, closeTo(800 - 32, 0.5));

    // Página visível renderizada de novo em resolução maior que a prévia.
    expect(backend.rasterRequests.where((r) => r.pages != null && r.dpi > 24), isNotEmpty);

    await tester.tap(find.byTooltip('Aumentar zoom'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget);
    expect(tester.getSize(page).width, closeTo(fitWidth * 1.25, 0.5));

    await tester.tap(find.byTooltip('Diminuir zoom'));
    await tester.tap(find.byTooltip('Diminuir zoom'));
    await tester.pumpAndSettle();
    expect(find.text('75%'), findsOneWidget);

    await tester.tap(find.text('75%')); // ajustar à largura
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byTooltip('Próxima página'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Próxima página'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Página anterior'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    // Ir para a página pelo diálogo.
    await tester.tap(find.text('2 / 3'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.text('Ir'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);

    // Toque duplo alterna o zoom.
    final center = tester.getCenter(find.byKey(const ValueKey('lib_pdf_page_0')));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(find.text('200%'), findsOneWidget);

    await tester.tap(find.byTooltip('Imprimir'));
    await tester.pumpAndSettle();
    expect(backend.printCalls, 1);
  });

  testWidgets('gera o PdfDocument ao abrir e mostra carregando', (tester) async {
    final backend = _FakeBackend();
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => PdfDocumentViewer.open(context, document: _document(), title: 'Relatório', backend: backend),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Abrir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Gerando PDF…'), findsOneWidget);
      // Espera a geração real do documento terminar.
      for (var i = 0; i < 100 && find.text('1 / 3').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Relatório'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('lib_pdf_page_2')), findsNothing); // fora da tela ainda
  });
}
