import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Gráfico de barras simples, sem dependências e sem animação — pode ser
/// exibido na tela ou capturado em um relatório com `WidgetSection`.
class GraficoBarras extends StatelessWidget {
  const GraficoBarras({
    super.key,
    required this.dados,
    this.titulo,
    this.cor = const Color(0xFF1F3A5F),
    this.formatarValor,
  });

  /// Rótulo → valor, na ordem de exibição.
  final Map<String, double> dados;
  final String? titulo;
  final Color cor;
  final String Function(double valor)? formatarValor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (titulo != null) ...[
            Text(
              titulo!,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF222222),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _BarrasPainter(
                dados: dados,
                cor: cor,
                formatarValor: formatarValor ?? (v) => v.toStringAsFixed(0),
                // O TextPainter não herda o tema; repassa a fonte do app.
                fonte: DefaultTextStyle.of(context).style.fontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarrasPainter extends CustomPainter {
  _BarrasPainter({
    required this.dados,
    required this.cor,
    required this.formatarValor,
    this.fonte,
  });

  final Map<String, double> dados;
  final Color cor;
  final String Function(double valor) formatarValor;
  final String? fonte;

  static const _eixoEsquerdo = 64.0;
  static const _eixoInferior = 24.0;
  static const _topo = 18.0;
  static const _linhasGrade = 4;

  @override
  void paint(Canvas canvas, Size size) {
    if (dados.isEmpty) return;

    final maximo = dados.values.fold<double>(0, math.max);
    final teto = maximo <= 0 ? 1.0 : maximo * 1.1;
    final area = Rect.fromLTRB(
      _eixoEsquerdo,
      _topo,
      size.width,
      size.height - _eixoInferior,
    );

    final grade = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = 1;
    for (var i = 0; i <= _linhasGrade; i++) {
      final valor = teto * i / _linhasGrade;
      final y = area.bottom - area.height * i / _linhasGrade;
      canvas.drawLine(Offset(area.left, y), Offset(area.right, y), grade);
      _texto(
        canvas,
        formatarValor(valor),
        Offset(area.left - 6, y),
        alinhamento: Alignment.centerRight,
        cor: const Color(0xFF666666),
      );
    }

    final larguraSlot = area.width / dados.length;
    final larguraBarra = larguraSlot * 0.6;
    final barra = Paint()..color = cor;

    var i = 0;
    for (final MapEntry(key: rotulo, value: valor) in dados.entries) {
      final centroX = area.left + larguraSlot * (i + 0.5);
      final altura = area.height * (valor / teto);
      final retangulo = Rect.fromLTWH(
        centroX - larguraBarra / 2,
        area.bottom - altura,
        larguraBarra,
        altura,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          retangulo,
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        barra,
      );
      _texto(
        canvas,
        formatarValor(valor),
        Offset(centroX, retangulo.top - 4),
        alinhamento: Alignment.bottomCenter,
        cor: const Color(0xFF222222),
        negrito: true,
      );
      _texto(
        canvas,
        rotulo,
        Offset(centroX, area.bottom + 6),
        alinhamento: Alignment.topCenter,
        cor: const Color(0xFF444444),
      );
      i++;
    }
  }

  void _texto(
    Canvas canvas,
    String texto,
    Offset ancora, {
    required Alignment alinhamento,
    required Color cor,
    bool negrito = false,
  }) {
    final pintor = TextPainter(
      text: TextSpan(
        text: texto,
        style: TextStyle(
          fontFamily: fonte,
          fontSize: 11,
          color: cor,
          fontWeight: negrito ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Alignment de -1..1 → deslocamento de 0..tamanho.
    final dx = (alinhamento.x + 1) / 2 * pintor.width;
    final dy = (alinhamento.y + 1) / 2 * pintor.height;
    pintor.paint(canvas, ancora - Offset(dx, dy));
    pintor.dispose();
  }

  @override
  bool shouldRepaint(_BarrasPainter oldDelegate) =>
      oldDelegate.dados != dados || oldDelegate.cor != cor;
}
