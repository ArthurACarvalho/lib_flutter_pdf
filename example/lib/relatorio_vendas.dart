import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'widgets/grafico_barras.dart';

const _azul = Color(0xFF1F3A5F);

const vendasPorMes = {
  'Jan': 12500.0,
  'Fev': 9800.0,
  'Mar': 15200.0,
  'Abr': 11000.0,
  'Mai': 17400.0,
  'Jun': 16100.0,
};

String reais(num valor) {
  final inteiro = valor.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return 'R\$ $inteiro,00';
}

/// Relatório de demonstração: widgets comuns do Flutter, gráficos (um
/// CustomPainter próprio e dois do fl_chart) e uma tabela longa paginada.
PdfDocument criarRelatorioVendas() {
  final pedidos = [
    for (var i = 1; i <= 120; i++)
      (numero: 1000 + i, cliente: 'Cliente ${String.fromCharCode(65 + i % 26)}${i % 7}', valor: 150.0 + (i * 73) % 900),
  ];

  final doc = PdfDocument(
    title: 'Relatório de Vendas',
    author: 'lib_pdf',
    theme: ThemeData(colorSchemeSeed: _azul),
  );

  doc.addPage(PdfMultiPage(
    margin: const EdgeInsets.fromLTRB(40, 32, 40, 32),
    header: (ctx) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const FlutterLogo(size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Relatório de Vendas', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _azul)),
          ),
          Text('1º semestre 2026', style: TextStyle(color: Colors.grey.shade700)),
        ],
      ),
    ),
    footer: (ctx) => Container(
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.grey.shade300))),
      child: Row(
        children: [
          const Text('Minha Empresa Ltda.', style: TextStyle(fontSize: 9)),
          const Spacer(),
          Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: const TextStyle(fontSize: 9)),
        ],
      ),
    ),
    build: (ctx) => [
      Row(
        children: [
          _indicador('Faturamento', reais(vendasPorMes.values.reduce((a, b) => a + b)), Icons.attach_money),
          const SizedBox(width: 12),
          _indicador('Pedidos', '${pedidos.length}', Icons.shopping_cart),
          const SizedBox(width: 12),
          _indicador('Ticket médio', reais(pedidos.map((p) => p.valor).reduce((a, b) => a + b) / pedidos.length), Icons.trending_up),
        ],
      ),
      const SizedBox(height: 20),
      const PdfKeepTogether(
        child: SizedBox(
          height: 240,
          child: GraficoBarras(titulo: 'Vendas por mês (CustomPainter)', dados: vendasPorMes, cor: _azul),
        ),
      ),
      const SizedBox(height: 12),
      PdfKeepTogether(
        child: Row(
          children: [
            Expanded(child: _cartao('Evolução (fl_chart)', SizedBox(height: 180, child: _graficoLinha()))),
            const SizedBox(width: 12),
            Expanded(child: _cartao('Por categoria (fl_chart)', SizedBox(height: 180, child: _graficoPizza()))),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const _Titulo('Pedidos'),
      const SizedBox(height: 8),
      PdfTable(
        columnWidths: const {0: FixedColumnWidth(70), 2: FixedColumnWidth(110)},
        border: TableBorder(horizontalInside: BorderSide(color: Colors.grey.shade300, width: 0.5)),
        header: TableRow(
          decoration: const BoxDecoration(color: _azul),
          children: [
            for (final titulo in ['Número', 'Cliente', 'Valor'])
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(titulo, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
        rows: [
          for (final (i, p) in pedidos.indexed)
            TableRow(
              decoration: BoxDecoration(color: i.isEven ? Colors.white : const Color(0xFFF3F6FA)),
              children: [
                Padding(padding: const EdgeInsets.all(6), child: Text('#${p.numero}')),
                Padding(padding: const EdgeInsets.all(6), child: Text(p.cliente)),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(reais(p.valor), textAlign: TextAlign.right),
                ),
              ],
            ),
        ],
      ),
      const PdfPageBreak(),
      const _Titulo('Observações'),
      const SizedBox(height: 8),
      const Text(
        'Este relatório foi escrito inteiramente com widgets do Flutter. Textos viram texto PDF real '
        '(selecionável e pesquisável), formas e gráficos viram vetores, e o conteúdo longo é quebrado '
        'entre páginas automaticamente, sem cortar linhas de texto nem linhas de tabela.',
        textAlign: TextAlign.justify,
      ),
    ],
  ));

  return doc;
}

/// Títulos usam o tema do documento, lido com o BuildContext normal.
class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Text(texto, style: Theme.of(context).textTheme.titleLarge);
}

Widget _indicador(String titulo, String valor, IconData icone) => Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(backgroundColor: _azul, child: Icon(icone, color: Colors.white, size: 20)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo, style: const TextStyle(fontSize: 11, color: Colors.black54)),
                    Text(valor, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

Widget _cartao(String titulo, Widget child) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );

Widget _graficoLinha() {
  final valores = vendasPorMes.values.toList();
  return LineChart(
    LineChartData(
      minY: 0,
      gridData: const FlGridData(drawVerticalLine: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (value, meta) => SideTitleWidget(
              meta: meta,
              child: Text('${(value / 1000).toStringAsFixed(0)}k', style: const TextStyle(fontSize: 9)),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) => SideTitleWidget(
              meta: meta,
              child: Text(vendasPorMes.keys.elementAt(value.toInt()), style: const TextStyle(fontSize: 9)),
            ),
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: [for (var i = 0; i < valores.length; i++) FlSpot(i.toDouble(), valores[i])],
          isCurved: true,
          color: _azul,
          barWidth: 2.5,
          belowBarData: BarAreaData(show: true, color: _azul.withValues(alpha: 0.15)),
        ),
      ],
    ),
    duration: Duration.zero,
  );
}

Widget _graficoPizza() {
  const cores = [Color(0xFF1F3A5F), Color(0xFF4F7CAC), Color(0xFF9EC1E6), Color(0xFFF2A541)];
  const partes = {'Peças': 42.0, 'Serviços': 28.0, 'Acessórios': 18.0, 'Outros': 12.0};
  return PieChart(
    PieChartData(
      sectionsSpace: 2,
      centerSpaceRadius: 28,
      sections: [
        for (final (i, e) in partes.entries.indexed)
          PieChartSectionData(
            value: e.value,
            color: cores[i],
            radius: 50,
            title: '${e.value.round()}%',
            titleStyle: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
          ),
      ],
    ),
    duration: Duration.zero,
  );
}
