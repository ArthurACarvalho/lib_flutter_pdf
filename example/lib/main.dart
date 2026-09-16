import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'relatorio_vendas.dart';
import 'widgets/grafico_barras.dart';

void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: ExemploPage()));

class ExemploPage extends StatefulWidget {
  const ExemploPage({super.key});

  @override
  State<ExemploPage> createState() => _ExemploPageState();
}

class _ExemploPageState extends State<ExemploPage> {
  bool _gerando = false;
  String? _resultado;

  Future<void> _gerar() async {
    setState(() {
      _gerando = true;
      _resultado = null;
    });
    try {
      final relogio = Stopwatch()..start();
      final bytes = await gerarRelatorioVendas();
      final pasta = await getApplicationDocumentsDirectory();
      final arquivo = File('${pasta.path}/relatorio_vendas.pdf');
      await arquivo.writeAsBytes(bytes);
      setState(() => _resultado = 'PDF salvo em ${arquivo.path}\n'
          '${(bytes.length / 1024).toStringAsFixed(1)} KB em ${relogio.elapsedMilliseconds} ms');
    } catch (e) {
      setState(() => _resultado = 'Erro: $e');
    } finally {
      setState(() => _gerando = false);
    }
  }

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
            onPressed: _gerando ? null : _gerar,
            icon: _gerando
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf),
            label: const Text('Gerar relatório'),
          ),
          if (_resultado != null) ...[
            const SizedBox(height: 16),
            SelectableText(_resultado!),
          ],
        ],
      ),
    );
  }
}
