import 'package:flutter/widgets.dart';

import 'markers.dart';

/// Uma [Table] do Flutter para relatórios: nunca corta uma linha ao meio
/// entre páginas e repete o [header] no topo de cada página de continuação.
class PdfTable extends StatelessWidget {
  const PdfTable({
    super.key,
    this.header,
    required this.rows,
    this.columnWidths,
    this.defaultColumnWidth = const FlexColumnWidth(),
    this.border,
    this.defaultVerticalAlignment = TableCellVerticalAlignment.top,
    this.textBaseline,
    this.repeatHeader = true,
  });

  /// Linha de cabeçalho (opcional).
  final TableRow? header;
  final List<TableRow> rows;
  final Map<int, TableColumnWidth>? columnWidths;
  final TableColumnWidth defaultColumnWidth;
  final TableBorder? border;
  final TableCellVerticalAlignment defaultVerticalAlignment;
  final TextBaseline? textBaseline;

  /// Repete o cabeçalho quando a tabela continua em outra página.
  final bool repeatHeader;

  @override
  Widget build(BuildContext context) {
    final table = Table(
      columnWidths: columnWidths,
      defaultColumnWidth: defaultColumnWidth,
      border: border,
      defaultVerticalAlignment: defaultVerticalAlignment,
      textBaseline: textBaseline,
      children: [?header, ...rows],
    );
    if (header == null || !repeatHeader) return table;
    return PdfRepeatHeader(child: table);
  }
}
