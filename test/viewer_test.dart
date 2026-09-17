import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

/// Simula o `printing`: lê os tamanhos das páginas do PDF e devolve imagens lisas.
class _FakeBackend extends PdfViewerBackend {
  final rasterRequests = <({List<int>? pages, double dpi})>[];
  int printCalls = 0;
  final shared = <({String name, Rect? bounds})>[];

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

  @override
  Future<bool> sharePdf(Uint8List pdf, {required String name, Rect? bounds}) async {
    shared.add((name: name, bounds: bounds));
    return true;
  }
}

PdfDocument _document() => PdfDocument()
  ..addPage(PdfMultiPage(
    build: (ctx) => const [Text('Página um'), PdfPageBreak(), Text('Página dois'), PdfPageBreak(), Text('Página três')],
  ));

void main() {
  testWidgets('navega, dá zoom, imprime e salva', (tester) async {
    final bytes = (await tester.runAsync(_document().save))!;
    final backend = _FakeBackend();
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PdfDocumentViewer.bytes(bytes, fileName: 'vendas.pdf', backend: backend)),
    ));
    await tester.pumpAndSettle();

    String pageField() => tester.widget<TextField>(find.byKey(const ValueKey('lib_pdf_page_field'))).controller!.text;

    expect(find.text('vendas.pdf'), findsOneWidget); // título padrão
    final order = ['Imprimir', 'Ajustar à página', 'Diminuir zoom', 'Aumentar zoom', 'Salvar'];
    final xs = [for (final tooltip in order) tester.getCenter(find.byTooltip(tooltip)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(find.byTooltip('Fechar'), findsNothing); // sem onClose
    expect(pageField(), '1');
    expect(find.text('/ 3'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final page = find.byKey(const ValueKey('lib_pdf_page_0'));
    final fitWidth = tester.getSize(page).width;
    expect(fitWidth, closeTo(800 - 48, 0.5));

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

    // Menu de zoom.
    await tester.tap(find.text('75%'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('150%').last);
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    expect(tester.getSize(page).width, closeTo(fitWidth * 1.5, 0.5));

    // Ajustar à página: a página inteira cabe na altura disponível.
    await tester.tap(find.byTooltip('Ajustar à página'));
    await tester.pumpAndSettle();
    final viewport = tester.getSize(find.byType(ListView));
    expect(tester.getSize(page).height, closeTo(viewport.height - 48, 0.5));
    expect(find.byTooltip('Ajustar à largura'), findsOneWidget);
    await tester.tap(find.byTooltip('Ajustar à largura'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
    expect(tester.getSize(page).width, closeTo(fitWidth, 0.5));

    await tester.tap(find.byTooltip('Próxima página'));
    await tester.pumpAndSettle();
    expect(pageField(), '2');
    await tester.tap(find.byTooltip('Próxima página'));
    await tester.pumpAndSettle();
    expect(pageField(), '3');
    await tester.tap(find.byTooltip('Página anterior'));
    await tester.pumpAndSettle();
    expect(pageField(), '2');

    // Digitar a página na caixa.
    await tester.enterText(find.byKey(const ValueKey('lib_pdf_page_field')), '1');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(pageField(), '1');
    await tester.tap(find.byKey(const ValueKey('lib_pdf_page_field')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('lib_pdf_page_field')), '3');
    await tester.tapAt(tester.getCenter(find.byType(ListView)));
    await tester.pumpAndSettle();
    expect(pageField(), '3');
    await tester.enterText(find.byKey(const ValueKey('lib_pdf_page_field')), '1');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(pageField(), '1');
    expect(tester.getTopLeft(page).dy, closeTo(tester.getTopLeft(find.byType(ListView)).dy + 24, 0.5));

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

    await tester.tap(find.byTooltip('Salvar'));
    await tester.pumpAndSettle();
    expect(backend.shared.single.name, 'vendas.pdf');
    expect(backend.shared.single.bounds, tester.getRect(find.byTooltip('Salvar')));
  });

  testWidgets('tela estreita mantém zoom só na barra inferior', (tester) async {
    final bytes = (await tester.runAsync(_document().save))!;
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PdfDocumentViewer.bytes(
          bytes,
          title: 'Relatório de vendas com um título bem comprido',
          onClose: () {},
          backend: _FakeBackend(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // sem overflow
    expect(find.byTooltip('Aumentar zoom'), findsNothing);
    expect(find.byTooltip('Imprimir'), findsOneWidget);
    expect(find.byTooltip('Fechar'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    final order = ['Imprimir', 'Salvar', 'Fechar'];
    final xs = [for (final tooltip in order) tester.getCenter(find.byTooltip(tooltip)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
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
      for (var i = 0; i < 100 && find.text('/ 3').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Relatório'), findsOneWidget);
    expect(find.text('/ 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('lib_pdf_page_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('lib_pdf_page_2')), findsNothing); // fora da tela ainda

    await tester.tap(find.byTooltip('Fechar'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir'), findsOneWidget);
  });
}
