import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'support/pdf_tools.dart';

const _lorem =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore '
    'et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut '
    'aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum '
    'dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui '
    'officia deserunt mollit anim id est laborum. ';

void main() {
  testWidgets('tabela longa pagina com cabeçalho repetido e numeração', (tester) async {
    final doc = PdfDocument(title: 'Paginação');
    TableRow row(List<String> cells, {bool bold = false}) => TableRow(
          decoration: bold ? const BoxDecoration(color: Color(0xFFE3EAF3)) : null,
          children: [
            for (final c in cells)
              Padding(
                padding: const EdgeInsets.all(4),
                child: Text(c, style: TextStyle(fontWeight: bold ? FontWeight.bold : null, fontSize: 10)),
              ),
          ],
        );

    doc.addPage(PdfMultiPage(
      header: (ctx) => Container(
        padding: const EdgeInsets.only(bottom: 8),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.black26))),
        child: const Text('Relatório de Pedidos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      footer: (ctx) => Align(
        alignment: Alignment.centerRight,
        child: Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: const TextStyle(fontSize: 9)),
      ),
      build: (ctx) => [
        const Text('Texto longo antes da tabela:', style: TextStyle(fontWeight: FontWeight.bold)),
        Text(_lorem * 12, textAlign: TextAlign.justify),
        const SizedBox(height: 16),
        PdfTable(
          border: TableBorder.all(color: Colors.black38, width: 0.5),
          columnWidths: const {0: FixedColumnWidth(50), 2: FixedColumnWidth(80)},
          header: row(['#', 'Cliente', 'Valor'], bold: true),
          rows: [for (var i = 1; i <= 200; i++) row(['$i', 'Cliente número $i da lista', 'R\$ ${i * 37},00'])],
        ),
        const PdfPageBreak(),
        const Text('Seção final após quebra forçada'),
      ],
    ));

    final watch = Stopwatch()..start();
    debugDisableShadows = false;
    final bytes = (await tester.runAsync(doc.save))!;
    debugDisableShadows = true;
    debugPrint('save() em ${watch.elapsedMilliseconds} ms, ${bytes.length} bytes');
    final path = '${PdfTools.outputDir()}/pagination.pdf';
    File(path).writeAsBytesSync(bytes);

    final check = PdfTools.run('qpdf', ['--check', path]);
    if (check != null) expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    final info = PdfTools.run('pdfinfo', [path]);
    if (info != null) debugPrint((info.stdout as String).split('\n').firstWhere((l) => l.startsWith('Pages')));

    final text = PdfTools.run('pdftotext', ['-layout', path, '-']);
    if (text != null) {
      final pages = (text.stdout as String).split('\f').where((p) => p.trim().isNotEmpty).toList();
      expect(pages.length, greaterThan(3));
      for (var i = 0; i < pages.length; i++) {
        expect(pages[i], contains('Página ${i + 1} de ${pages.length}'));
        expect(pages[i], contains('Relatório de Pedidos'));
      }
      // Cabeçalho da tabela repetido nas páginas de continuação.
      final withHeader = pages.where((p) => RegExp(r'#\s+Cliente\s+Valor').hasMatch(p)).length;
      expect(withHeader, greaterThan(2));
      expect(pages.last, contains('Seção final após quebra forçada'));
      // Nenhuma linha da tabela cortada/duplicada: cada número aparece uma vez.
      final all = pages.join('\n');
      for (final i in [1, 57, 123, 200]) {
        expect(RegExp('Cliente número $i da lista').allMatches(all).length, 1, reason: 'linha $i');
      }
    }
  });
}
