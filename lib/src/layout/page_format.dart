import 'package:flutter/widgets.dart';

/// Tamanho de página em pontos (1/72 de polegada). No layout, 1 pixel
/// lógico do Flutter corresponde a 1 ponto.
@immutable
class PdfPageFormat {
  const PdfPageFormat(this.width, this.height);

  static const PdfPageFormat a3 = PdfPageFormat(841.89, 1190.55);
  static const PdfPageFormat a4 = PdfPageFormat(595.28, 841.89);
  static const PdfPageFormat a5 = PdfPageFormat(419.53, 595.28);
  static const PdfPageFormat letter = PdfPageFormat(612, 792);
  static const PdfPageFormat legal = PdfPageFormat(612, 1008);

  /// Pontos por centímetro e por milímetro, para margens em unidades métricas.
  static const double cm = 72 / 2.54;
  static const double mm = cm / 10;

  final double width;
  final double height;

  Size get size => Size(width, height);

  PdfPageFormat get landscape => width >= height ? this : PdfPageFormat(height, width);

  PdfPageFormat get portrait => height >= width ? this : PdfPageFormat(height, width);

  @override
  bool operator ==(Object other) => other is PdfPageFormat && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'PdfPageFormat($width x $height)';
}
