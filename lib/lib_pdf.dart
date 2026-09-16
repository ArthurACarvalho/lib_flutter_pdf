/// Relatórios PDF escritos com widgets comuns do Flutter.
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:lib_pdf/lib_pdf.dart';
///
/// final doc = PdfDocument(title: 'Vendas')
///   ..addPage(PdfMultiPage(
///     header: (ctx) => const Text('Relatório de Vendas'),
///     footer: (ctx) => Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}'),
///     build: (ctx) => [const Text('Conteúdo')],
///   ));
/// final bytes = await doc.save();
/// ```
library;

export 'src/font/font_registry.dart' show PdfFont;
export 'src/layout/page_format.dart';
export 'src/layout/pdf_context.dart' show PdfContext;
export 'src/pdf_document.dart';
export 'src/widgets/markers.dart' show PdfKeepTogether, PdfPageBreak, PdfRasterize;
export 'src/widgets/pdf_table.dart';
