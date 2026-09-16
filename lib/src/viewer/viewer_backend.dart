import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:printing/printing.dart' show Printing;

/// Operações dependentes de plataforma usadas pelo visualizador: converter
/// páginas do PDF em imagens e abrir o diálogo de impressão.
///
/// O padrão usa o pacote `printing`. Substitua para testes ou para usar
/// outro renderizador.
abstract class PdfViewerBackend {
  const PdfViewerBackend();

  /// Implementação padrão, com o pacote `printing`.
  static const PdfViewerBackend printing = _PrintingBackend();

  /// Imagens das páginas (índices a partir de 0; todas se [pages] for nulo),
  /// renderizadas com [dpi] pixels por polegada.
  Stream<ui.Image> rasterize(Uint8List pdf, {List<int>? pages, required double dpi});

  /// Abre o diálogo de impressão do sistema. Retorna falso se foi cancelado.
  Future<bool> printPdf(Uint8List pdf, {required String name});
}

class _PrintingBackend extends PdfViewerBackend {
  const _PrintingBackend();

  // Na Web o pdf.js transfere o ArrayBuffer recebido para um worker, o que
  // invalida o buffer original. Por isso cada chamada recebe uma cópia.

  @override
  Stream<ui.Image> rasterize(Uint8List pdf, {List<int>? pages, required double dpi}) async* {
    await for (final raster in Printing.raster(Uint8List.fromList(pdf), pages: pages, dpi: dpi)) {
      yield await raster.toImage();
    }
  }

  @override
  Future<bool> printPdf(Uint8List pdf, {required String name}) =>
      Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(pdf), name: name);
}
