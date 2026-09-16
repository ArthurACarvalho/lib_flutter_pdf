import 'package:flutter/material.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'relatorio_vendas.dart';
import 'widgets/grafico_barras.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: ExemploPage()));

class ExemploPage extends StatelessWidget {
  const ExemploPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('lib_pdf — exemplo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('O mesmo widget de gráfico usado na tela vai para o PDF como vetor:'),
          const SizedBox(
            height: 240,
            child: GraficoBarras(titulo: 'Vendas por mês', dados: vendasPorMes),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            // Gera o PDF e abre o visualizador (zoom, páginas e impressão).
            onPressed: () => PdfDocumentViewer.open(
              context,
              document: criarRelatorioVendas(),
              title: 'Relatório de Vendas',
              fileName: 'relatorio_vendas.pdf',
            ),
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('Abrir relatório'),
          ),
        ],
      ),
    );
  }
}
