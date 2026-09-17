import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

void main() {
  testWidgets('desempenho: tabela com 2000 linhas', (tester) async {
    final doc = PdfDocument()
      ..addPage(
        PdfMultiPage(
          footer: (ctx) => Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}'),
          build: (ctx) => [
            PdfTable(
              border: TableBorder.all(width: 0.5),
              header: const TableRow(children: [Text('A'), Text('B'), Text('C')]),
              rows: [
                for (var i = 0; i < 2000; i++)
                  TableRow(children: [Text('$i'), Text('Linha número $i'), Text('${i * 3}')]),
              ],
            ),
          ],
        ),
      );
    final watch = Stopwatch()..start();
    final bytes = (await tester.runAsync(doc.save))!;
    debugPrint('2000 linhas: ${watch.elapsedMilliseconds} ms, ${bytes.length ~/ 1024} KB');
  }, tags: ['perf']);
}
