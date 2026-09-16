import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../font/ttf_parser.dart';
import 'pdf_canvas.dart';
import 'vector_context.dart';

class _Run {
  _Run(this.start, this.end, this.style);

  final int start;
  final int end;
  final TextStyle style;
}

/// Converte um [RenderParagraph] em texto PDF real (selecionável e
/// pesquisável), posicionando cada palavra exatamente onde o motor de texto
/// do Flutter a colocou.
class ParagraphEmitter {
  ParagraphEmitter(this.canvas);

  final PdfCanvas canvas;

  /// Retorna falso quando o parágrafo não pode ser emitido como texto
  /// (o chamador então usa a pintura normal, que vira imagem).
  bool emit(VectorPaintingContext context, RenderParagraph paragraph, Offset offset) {
    if (paragraph.textDirection != TextDirection.ltr) return false;
    final session = canvas.session;

    final painter = TextPainter(
      text: paragraph.text,
      textAlign: paragraph.textAlign,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      maxLines: paragraph.maxLines,
      ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
      locale: paragraph.locale,
      strutStyle: paragraph.strutStyle,
      textWidthBasis: paragraph.textWidthBasis,
      textHeightBehavior: paragraph.textHeightBehavior,
    );
    try {
      final placeholders = _placeholderDimensions(paragraph);
      if (placeholders == null) return false;
      painter.setPlaceholderDimensions(placeholders);
      final constraints = paragraph.constraints;
      final wrap = paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
      painter.layout(
        minWidth: constraints.minWidth,
        maxWidth: wrap ? constraints.maxWidth : double.infinity,
      );

      final overflowed = paragraph.size.height < painter.height ||
          paragraph.size.width < painter.width ||
          painter.didExceedMaxLines;
      if (overflowed &&
          (paragraph.overflow == TextOverflow.ellipsis || paragraph.overflow == TextOverflow.fade)) {
        return false;
      }

      final plain = paragraph.text.toPlainText(includeSemanticsLabels: false);
      final runs = <_Run>[];
      if (!_collectRuns(paragraph.text, null, runs, 0)) return false;

      // Resolve as fontes antes de desenhar qualquer coisa.
      final fonts = <_Run, TtfFont>{};
      for (final run in runs) {
        final style = run.style;
        final font = session.fonts.resolve(style.fontFamily, style.fontWeight, style.fontStyle);
        if (font == null || (font.isCff && font.cffOutlines == null)) return false;
        final text = plain.substring(run.start, run.end);
        for (final rune in text.runes) {
          if (rune <= 0x20 || rune == 0xA0) continue;
          if (!font.hasGlyph(rune)) return false;
        }
        fonts[run] = font;
      }

      final lines = painter.computeLineMetrics();
      final clip = overflowed && paragraph.overflow != TextOverflow.visible;
      if (clip) {
        canvas.save();
        canvas.clipRect(offset & paragraph.size);
      }

      for (final run in runs) {
        _emitRun(painter, plain, run, fonts[run]!, lines, offset);
      }

      if (clip) canvas.restore();

      // Widgets embutidos no texto (WidgetSpan).
      var child = paragraph.firstChild;
      while (child != null) {
        final parentData = child.parentData! as TextParentData;
        final childOffset = parentData.offset;
        if (childOffset != null) context.paintChild(child, childOffset + offset);
        child = parentData.nextSibling;
      }
      return true;
    } finally {
      painter.dispose();
    }
  }

  List<PlaceholderDimensions>? _placeholderDimensions(RenderParagraph paragraph) {
    final result = <PlaceholderDimensions>[];
    var child = paragraph.firstChild;
    while (child != null) {
      final parentData = child.parentData! as TextParentData;
      final span = parentData.span;
      if (span == null || !child.hasSize) return null;
      double? baselineOffset;
      if (span.alignment == ui.PlaceholderAlignment.baseline) {
        baselineOffset = child.getDistanceToBaseline(span.baseline ?? TextBaseline.alphabetic);
      }
      result.add(PlaceholderDimensions(
        size: child.size,
        alignment: span.alignment,
        baseline: span.baseline,
        baselineOffset: baselineOffset,
      ));
      child = parentData.nextSibling;
    }
    return result;
  }

  /// Percorre a árvore de spans herdando estilos; falso se houver algo que
  /// o texto PDF não reproduz (sombras, foreground com shader).
  bool _collectRuns(InlineSpan span, TextStyle? parent, List<_Run> runs, int start) {
    var position = start;
    bool visit(InlineSpan s, TextStyle? inherited) {
      final style = inherited == null ? s.style : inherited.merge(s.style);
      if (s is TextSpan) {
        final text = s.text;
        if (text != null && text.isNotEmpty) {
          final effective = style ?? const TextStyle();
          if (effective.shadows?.isNotEmpty ?? false) return false;
          final foreground = effective.foreground;
          if (foreground != null && (foreground.shader != null || foreground.maskFilter != null)) {
            return false;
          }
          runs.add(_Run(position, position + text.length, effective));
          position += text.length;
        }
        for (final child in s.children ?? const <InlineSpan>[]) {
          if (!visit(child, style)) return false;
        }
        return true;
      }
      if (s is PlaceholderSpan) {
        position += 1; // U+FFFC
        return true;
      }
      return false;
    }

    return visit(span, parent);
  }

  void _emitRun(
    TextPainter painter,
    String plain,
    _Run run,
    TtfFont font,
    List<ui.LineMetrics> lines,
    Offset offset,
  ) {
    final style = run.style;
    final fontSize = painter.textScaler.scale(style.fontSize ?? 14);
    final color = style.foreground?.color ?? style.color ?? const Color(0xFF000000);
    final letterSpacing = style.letterSpacing ?? 0;
    // Fontes CFF (ex.: MaterialIcons) viram contornos; TrueType vira texto.
    final embedded = font.isCff ? null : canvas.session.doc.font(font);

    final weight = style.fontWeight?.value ?? 400;
    final fakeBold = weight >= 600 && font.weightClass < 600;
    final fakeItalic = style.fontStyle == FontStyle.italic && !font.italic;

    final background = style.background?.color ?? style.backgroundColor;
    final decoration = style.decoration ?? TextDecoration.none;

    List<TextBox> runBoxes() =>
        painter.getBoxesForSelection(TextSelection(baseOffset: run.start, extentOffset: run.end));

    if (background != null) {
      final paint = Paint()..color = background;
      for (final box in runBoxes()) {
        canvas.drawRect(box.toRect().shift(offset), paint);
      }
    }

    // Palavras: sequências sem espaço dentro do run.
    var i = run.start;
    while (i < run.end) {
      while (i < run.end && _isSpace(plain.codeUnitAt(i))) {
        i++;
      }
      if (i >= run.end) break;
      var j = i;
      while (j < run.end && !_isSpace(plain.codeUnitAt(j))) {
        j++;
      }
      _emitWord(
        painter: painter,
        text: plain.substring(i, j),
        start: i,
        font: font,
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        lines: lines,
        offset: offset,
        draw: (origin, glyphs, positions) {
          if (embedded == null) {
            canvas.drawGlyphOutlines(
              font: font,
              fontSize: fontSize,
              origin: origin,
              glyphs: glyphs,
              positions: positions,
              color: color,
              skewX: fakeItalic ? 0.25 : 0,
            );
          } else {
            canvas.drawGlyphRun(
              font: embedded,
              fontSize: fontSize,
              origin: origin,
              glyphs: glyphs,
              positions: positions,
              color: color,
              skewX: fakeItalic ? 0.25 : 0,
              fakeBold: fakeBold,
            );
          }
        },
        embedded: (glyph, text) => embedded?.useGlyph(glyph, text),
      );
      i = j;
    }

    if (decoration != TextDecoration.none) {
      for (final box in runBoxes()) {
        final rect = box.toRect().shift(offset);
        final baseline = _baselineFor(lines, box.toRect()) + offset.dy;
        _decorate(style, font, fontSize, rect, baseline, color);
      }
    }
  }

  void _emitWord({
    required TextPainter painter,
    required String text,
    required int start,
    required TtfFont font,
    required double fontSize,
    required double letterSpacing,
    required List<ui.LineMetrics> lines,
    required Offset offset,
    required void Function(Offset origin, List<int> glyphs, List<double> positions) draw,
    required void Function(int glyph, String text) embedded,
  }) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + text.length),
    );
    if (boxes.isEmpty) return;

    if (boxes.length > 1 && text.runes.length > 1) {
      // Palavra quebrada entre linhas: posiciona caractere a caractere.
      var k = 0;
      for (final rune in text.runes) {
        final len = rune > 0xFFFF ? 2 : 1;
        _emitWord(
          painter: painter,
          text: text.substring(k, k + len),
          start: start + k,
          font: font,
          fontSize: fontSize,
          letterSpacing: letterSpacing,
          lines: lines,
          offset: offset,
          draw: draw,
          embedded: embedded,
        );
        k += len;
      }
      return;
    }

    final box = boxes.first.toRect();
    // Palavras fora da página atual (parágrafo dividido entre páginas).
    if (!canvas.isVisible(box.shift(offset))) return;
    final glyphs = <int>[];
    final positions = <double>[];
    var pen = 0.0;
    var k = 0;
    for (final rune in text.runes) {
      final len = rune > 0xFFFF ? 2 : 1;
      final glyph = font.glyphForCodePoint(rune);
      glyphs.add(glyph);
      positions.add(pen);
      embedded(glyph, text.substring(k, k + len));
      pen += font.advance1000(glyph) * fontSize / 1000 + letterSpacing;
      k += len;
    }
    // Ajusta a largura natural à caixa do layout (kerning e ligaduras do
    // motor de texto podem deixar a palavra um pouco mais curta).
    final natural = pen - letterSpacing;
    final target = box.width - (letterSpacing > 0 ? letterSpacing : 0);
    if (natural > 0 && target > 0) {
      final factor = target / natural;
      if (factor > 0.85 && factor < 1.15) {
        for (var p = 0; p < positions.length; p++) {
          positions[p] *= factor;
        }
      }
    }
    final baseline = _baselineFor(lines, box);
    draw(Offset(box.left + offset.dx, baseline + offset.dy), glyphs, positions);
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x2028 || c == 0xFFFC;

  double _baselineFor(List<ui.LineMetrics> lines, Rect box) {
    final center = box.center.dy;
    ui.LineMetrics? best;
    var bestDistance = double.infinity;
    for (final line in lines) {
      final top = line.baseline - line.ascent;
      final bottom = line.baseline + line.descent;
      if (center >= top && center <= bottom) return line.baseline;
      final d = math.min((center - top).abs(), (center - bottom).abs());
      if (d < bestDistance) {
        bestDistance = d;
        best = line;
      }
    }
    return best?.baseline ?? box.bottom;
  }

  void _decorate(TextStyle style, TtfFont font, double fontSize, Rect rect, double baseline, Color textColor) {
    final decoration = style.decoration!;
    final color = style.decorationColor ?? textColor;
    final scale = fontSize / font.unitsPerEm;
    final thicknessFactor = style.decorationThickness ?? 1;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;

    void line(double y, double thickness) {
      paint.strokeWidth = math.max(thickness * thicknessFactor, 0.25);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
      if (style.decorationStyle == TextDecorationStyle.double) {
        final gap = paint.strokeWidth * 2;
        canvas.drawLine(Offset(rect.left, y + gap), Offset(rect.right, y + gap), paint);
      }
    }

    final underlineThickness = font.underlineThickness != 0 ? font.underlineThickness * scale : fontSize / 14;
    if (decoration.contains(TextDecoration.underline)) {
      final position = font.underlinePosition != 0 ? -font.underlinePosition * scale : fontSize / 10;
      line(baseline + position, underlineThickness);
    }
    if (decoration.contains(TextDecoration.lineThrough)) {
      final position = font.strikeoutPosition != 0 ? font.strikeoutPosition * scale : fontSize * 0.3;
      final size = font.strikeoutSize != 0 ? font.strikeoutSize * scale : underlineThickness;
      line(baseline - position, size);
    }
    if (decoration.contains(TextDecoration.overline)) {
      line(baseline - font.ascender * scale, underlineThickness);
    }
  }
}
