import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'support/grafico_barras.dart';
import 'support/pdf_tools.dart';

void main() {
  testWidgets('página única com widgets comuns e gráfico vetorial', (tester) async {
    final doc = PdfDocument(title: 'Teste básico');
    doc.addPage(PdfPage(
      build: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Builder(builder: (context) => Text('Relatório de Vendas', style: Theme.of(context).textTheme.headlineMedium)),
          const Text('Olá, acentuação: ação, pão, você — «teste»', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Row(children: [
            Container(width: 80, height: 40, color: Colors.red),
            const SizedBox(width: 8),
            Container(
              width: 120,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.blue.shade100,
                border: Border.all(color: Colors.blue, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: const Text('Caixa', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ]),
          const Card(child: ListTile(title: Text('Total'), subtitle: Text('Setembro'), trailing: Text('R\$ 65.900'))),
          const SizedBox(
            height: 260,
            child: GraficoBarras(
              titulo: 'Vendas por mês',
              dados: {'Jan': 12500, 'Fev': 9800, 'Mar': 15200, 'Abr': 11000, 'Mai': 17400},
            ),
          ),
        ],
      ),
    ));
    final bytes = (await tester.runAsync(doc.save))!;
    expect(String.fromCharCodes(bytes.take(8)), '%PDF-1.7');
    final path = '${PdfTools.outputDir()}/basic.pdf';
    File(path).writeAsBytesSync(bytes);

    final check = PdfTools.run('qpdf', ['--check', path]);
    if (check != null) expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    final text = PdfTools.run('pdftotext', [path, '-']);
    if (text != null) {
      expect(text.stdout, contains('Relatório de Vendas'));
      expect(text.stdout, contains('ação, pão, você'));
    }
  });
}
