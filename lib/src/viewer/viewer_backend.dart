import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:printing/printing.dart' show Printing;

/// Operações dependentes de plataforma usadas pelo visualizador: converter
/// páginas do PDF em imagens, imprimir e compartilhar.
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

  /// Abre o compartilhamento do sistema, que inclui "Salvar em Arquivos" e o
  /// Google Drive. [bounds] é a área do botão na tela, onde a janela se ancora
  /// no iPad.
  Future<bool> sharePdf(Uint8List pdf, {required String name, ui.Rect? bounds});
}

class _PrintingBackend extends PdfViewerBackend {
  const _PrintingBackend();

  @override
  Stream<ui.Image> rasterize(Uint8List pdf, {List<int>? pages, required double dpi}) async* {
    await for (final raster in Printing.raster(pdf, pages: pages, dpi: dpi)) {
      yield await raster.toImage();
    }
  }

  @override
  Future<bool> printPdf(Uint8List pdf, {required String name}) =>
      Printing.layoutPdf(onLayout: (_) async => pdf, name: name);

  @override
  Future<bool> sharePdf(Uint8List pdf, {required String name, ui.Rect? bounds}) =>
      Printing.sharePdf(bytes: pdf, filename: name, bounds: bounds);
}
