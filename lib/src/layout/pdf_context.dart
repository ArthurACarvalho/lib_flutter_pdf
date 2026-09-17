import 'package:flutter/widgets.dart';

import 'page_format.dart';

/// Informações da página sendo construída, recebidas pelos builders de
/// cabeçalho, rodapé e conteúdo.
@immutable
class PdfContext {
  const PdfContext({required this.pageNumber, required this.pagesCount, required this.format});

  /// Número da página no documento, começando em 1.
  final int pageNumber;

  /// Total de páginas do documento.
  ///
  /// No conteúdo de um `PdfMultiPage` (que é construído antes da paginação)
  /// e na primeira medição de cabeçalhos e rodapés este valor ainda é 0.
  final int pagesCount;

  final PdfPageFormat format;

  /// Contexto da página em qualquer widget dentro do relatório.
  static PdfContext of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PdfPageScope>();
    assert(scope != null, 'PdfContext.of chamado fora de um documento lib_pdf');
    return scope!.pdf;
  }

  static PdfContext? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PdfPageScope>()?.pdf;

  @override
  bool operator ==(Object other) =>
      other is PdfContext && other.pageNumber == pageNumber && other.pagesCount == pagesCount && other.format == format;

  @override
  int get hashCode => Object.hash(pageNumber, pagesCount, format);
}

class PdfPageScope extends InheritedWidget {
  const PdfPageScope({super.key, required this.pdf, required super.child});

  final PdfContext pdf;

  @override
  bool updateShouldNotify(PdfPageScope oldWidget) => oldWidget.pdf != pdf;
}
