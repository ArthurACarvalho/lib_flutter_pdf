import 'package:flutter/rendering.dart';

import '../core/objects.dart';
import 'vector_context.dart';

/// Pinta um [RenderDecoratedBox] cujo `BoxDecoration` tem gradiente linear ou
/// radial usando shadings PDF (vetoriais). Retorna falso se a decoração usar
/// algo que não dá para reproduzir assim; o chamador então pinta normalmente.
bool paintGradientDecoration(VectorPaintingContext context, RenderDecoratedBox box, Offset offset) {
  final decoration = box.decoration;
  if (decoration is! BoxDecoration) return false;
  final gradient = decoration.gradient;
  if (gradient == null || decoration.image != null || decoration.backgroundBlendMode != null) return false;
  if (gradient.transform != null || gradient.colors.any((c) => c.a < 1)) return false;
  if (gradient is! LinearGradient && gradient is! RadialGradient) return false;
  if (gradient is LinearGradient && gradient.tileMode != TileMode.clamp) return false;
  if (gradient is RadialGradient && gradient.tileMode != TileMode.clamp) return false;

  final canvas = context.pdfCanvas;
  final configuration = box.configuration.copyWith(size: box.size);
  final textDirection = configuration.textDirection ?? TextDirection.ltr;
  final rect = offset & box.size;

  void paintDecoration() {
    if (decoration.boxShadow?.isNotEmpty ?? false) {
      final shadows = BoxDecoration(
        boxShadow: decoration.boxShadow,
        borderRadius: decoration.borderRadius,
        shape: decoration.shape,
      ).createBoxPainter();
      shadows.paint(canvas, offset, configuration);
      shadows.dispose();
    }

    final shading = _shading(gradient, rect, textDirection);
    final ref = canvas.session.doc.addShading(shading);
    canvas.save();
    if (decoration.shape == BoxShape.circle) {
      canvas.clipOval(Rect.fromCircle(center: rect.center, radius: rect.shortestSide / 2));
    } else if (decoration.borderRadius != null) {
      canvas.clipRRect(decoration.borderRadius!.resolve(textDirection).toRRect(rect));
    } else {
      canvas.clipRect(rect);
    }
    canvas.paintShading(ref.name, ref.ref);
    canvas.restore();

    if (decoration.border != null) {
      final border = BoxDecoration(
        border: decoration.border,
        borderRadius: decoration.borderRadius,
        shape: decoration.shape,
      ).createBoxPainter();
      border.paint(canvas, offset, configuration);
      border.dispose();
    }
  }

  if (box.position == DecorationPosition.background) paintDecoration();
  final child = box.child;
  if (child != null) context.paintChild(child, offset);
  if (box.position == DecorationPosition.foreground) paintDecoration();
  return true;
}

PdfDict _shading(Gradient gradient, Rect rect, TextDirection textDirection) {
  final colors = gradient.colors;
  var stops =
      gradient.stops ?? [for (var i = 0; i < colors.length; i++) colors.length == 1 ? 0.0 : i / (colors.length - 1)];

  // Garante paradas cobrindo [0, 1] em ordem estritamente crescente.
  final points = <(double, Color)>[for (var i = 0; i < colors.length; i++) (stops[i].clamp(0.0, 1.0), colors[i])];
  if (points.first.$1 > 0) points.insert(0, (0, points.first.$2));
  if (points.last.$1 < 1) points.add((1, points.last.$2));
  for (var i = 1; i < points.length; i++) {
    if (points[i].$1 <= points[i - 1].$1) points[i] = (points[i - 1].$1 + 1e-4, points[i].$2);
  }
  stops = [for (final p in points) p.$1];

  PdfArray rgb(Color c) => PdfArray.nums([c.r, c.g, c.b]);
  PdfDict segment(Color a, Color b) => PdfDict({
    'FunctionType': const PdfNum(2),
    'Domain': PdfArray.nums([0, 1]),
    'C0': rgb(a),
    'C1': rgb(b),
    'N': const PdfNum(1),
  });

  final PdfDict function;
  if (points.length == 2) {
    function = segment(points[0].$2, points[1].$2);
  } else {
    function = PdfDict({
      'FunctionType': const PdfNum(3),
      'Domain': PdfArray.nums([stops.first, stops.last]),
      'Functions': PdfArray([for (var i = 0; i + 1 < points.length; i++) segment(points[i].$2, points[i + 1].$2)]),
      'Bounds': PdfArray.nums(stops.sublist(1, stops.length - 1)),
      'Encode': PdfArray.nums([
        for (var i = 0; i + 1 < points.length; i++) ...[0, 1],
      ]),
    });
  }

  if (gradient is LinearGradient) {
    final begin = gradient.begin.resolve(textDirection).withinRect(rect);
    final end = gradient.end.resolve(textDirection).withinRect(rect);
    return PdfDict({
      'ShadingType': const PdfNum(2),
      'ColorSpace': const PdfName('DeviceRGB'),
      'Coords': PdfArray.nums([begin.dx, begin.dy, end.dx, end.dy]),
      'Domain': PdfArray.nums([stops.first, stops.last]),
      'Function': function,
      'Extend': PdfArray([const PdfBool(true), const PdfBool(true)]),
    });
  }
  final radial = gradient as RadialGradient;
  final center = radial.center.resolve(textDirection).withinRect(rect);
  final radius = radial.radius * rect.shortestSide;
  final focal = radial.focal?.resolve(textDirection).withinRect(rect) ?? center;
  final focalRadius = radial.focalRadius * rect.shortestSide;
  return PdfDict({
    'ShadingType': const PdfNum(3),
    'ColorSpace': const PdfName('DeviceRGB'),
    'Coords': PdfArray.nums([focal.dx, focal.dy, focalRadius, center.dx, center.dy, radius]),
    'Domain': PdfArray.nums([stops.first, stops.last]),
    'Function': function,
    'Extend': PdfArray([const PdfBool(true), const PdfBool(true)]),
  });
}
