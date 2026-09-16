import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../core/content.dart';
import '../core/objects.dart';
import '../font/embedded_font.dart';
import '../font/ttf_parser.dart';
import 'render_session.dart';

/// Estado gráfico espelhado entre o `save/restore` do Flutter e o `q/Q` do
/// PDF, para emitir só as mudanças necessárias.
class _GState {
  _GState(this.ctm, this.clip);

  _GState.copy(_GState o)
      : ctm = o.ctm.clone(),
        clip = o.clip,
        fill = o.fill,
        stroke = o.stroke,
        lineWidth = o.lineWidth,
        cap = o.cap,
        join = o.join,
        miter = o.miter,
        alphaKey = o.alphaKey;

  Matrix4 ctm;

  /// Recorte atual em coordenadas do dispositivo (página).
  Rect clip;

  int? fill;
  int? stroke;
  double? lineWidth;
  int? cap;
  int? join;
  double? miter;
  String? alphaKey;

  /// Preenchido quando este nível foi aberto por `saveLayer`.
  _Layer? layer;
}

class _Layer {
  _Layer(this.parent, this.alpha, this.bounds);

  final PdfContent parent;
  final double alpha;
  final Rect bounds;
}

/// Ponto de retorno para desfazer o que foi desenhado (ver [PdfCanvas.rollback]).
class PdfCanvasCheckpoint {
  PdfCanvasCheckpoint._(this.content, this.length, this.depth, this._state, this.jobs);

  final PdfContent content;
  final int length;
  final int depth;
  final _GState _state;
  final int jobs;
}

/// Implementação de [ui.Canvas] que traduz chamadas de desenho do Flutter em
/// operadores PDF vetoriais.
///
/// O que o PDF não consegue representar diretamente (texto de `TextPainter`,
/// shaders, sombras, filtros) é desenhado num `PictureRecorder` e embutido
/// como imagem no lugar exato. Quando uma operação não pode ser reproduzida
/// nem assim, [unsupported] fica verdadeiro para que o chamador rasterize a
/// subárvore inteira.
class PdfCanvas implements ui.Canvas {
  PdfCanvas({
    required this.session,
    required PdfContent content,
    required Rect deviceClip,
    Matrix4? transform,
  }) : _content = content { // ignore: prefer_initializing_formals
    _stack.add(_GState(transform ?? Matrix4.identity(), deviceClip));
  }

  final PdfRenderSession session;
  PdfContent _content;
  final List<_GState> _stack = [];

  /// Marcado quando alguma operação não pôde ser convertida.
  bool unsupported = false;

  _GState get _s => _stack.last;

  PdfContent get content => _content;

  Matrix4 get currentTransform => _s.ctm;

  Rect get deviceClipBounds => _s.clip;

  // ---------------------------------------------------------------------------
  // Checkpoints (usados para trocar uma subárvore por imagem).

  PdfCanvasCheckpoint checkpoint() => PdfCanvasCheckpoint._(
        _content,
        _content.buf.length,
        _stack.length,
        _GState.copy(_s)..layer = _s.layer,
        session.jobCount,
      );

  void rollback(PdfCanvasCheckpoint cp) {
    assert(identical(cp.content, _content) && cp.depth == _stack.length);
    _content.buf.truncate(cp.length);
    _stack[_stack.length - 1] = cp._state;
    session.rollbackJobs(cp.jobs);
  }

  // ---------------------------------------------------------------------------
  // Estado e transformações.

  @override
  void save() {
    _content.save();
    _stack.add(_GState.copy(_s));
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    if (!_isSimplePaint(paint, allowShader: false)) unsupported = true;
    final alpha = paint.color.a;
    final local = getLocalClipBounds();
    final area = bounds == null ? local : bounds.intersect(local);
    final layer = _Layer(_content, alpha, area);
    _stack.add(_GState.copy(_s)
      ..layer = layer
      // Grupos de transparência começam com alfa 1.
      ..alphaKey = null);
    _content = PdfContent();
  }

  @override
  void restore() {
    if (_stack.length <= 1) return;
    final popped = _stack.removeLast();
    final layer = popped.layer;
    if (layer == null) {
      _content.restore();
      return;
    }
    final group = _content;
    _content = layer.parent;
    if (group.isEmpty || layer.bounds.isEmpty) return;
    final form = session.doc.addForm(
      group,
      bbox: [layer.bounds.left, layer.bounds.top, layer.bounds.right, layer.bounds.bottom],
      transparencyGroup: true,
    );
    _content.save();
    if (layer.alpha < 1) {
      final gs = session.doc.extGState(fillAlpha: layer.alpha, strokeAlpha: layer.alpha);
      _content.extGState(gs.name, gs.ref);
    }
    _content.xObject(form.name, form.ref);
    _content.restore();
  }

  @override
  void restoreToCount(int count) {
    while (_stack.length > math.max(1, count)) {
      restore();
    }
  }

  @override
  int getSaveCount() => _stack.length;

  void _concat(Matrix4 m) {
    _s.ctm.multiply(m);
    final s = m.storage;
    _content.transform(s[0], s[1], s[4], s[5], s[12], s[13]);
  }

  @override
  void translate(double dx, double dy) {
    if (dx == 0 && dy == 0) return;
    _s.ctm.translateByDouble(dx, dy, 0, 1);
    _content.transform(1, 0, 0, 1, dx, dy);
  }

  @override
  void scale(double sx, [double? sy]) => _concat(Matrix4.diagonal3Values(sx, sy ?? sx, 1));

  @override
  void rotate(double radians) => _concat(Matrix4.rotationZ(radians));

  @override
  void skew(double sx, double sy) {
    final m = Matrix4.identity()
      ..setEntry(0, 1, sx)
      ..setEntry(1, 0, sy);
    _concat(m);
  }

  @override
  void transform(Float64List matrix4) => _concat(Matrix4.fromFloat64List(matrix4));

  @override
  Float64List getTransform() => Float64List.fromList(_s.ctm.storage);

  @override
  Rect getDestinationClipBounds() => _s.clip;

  @override
  Rect getLocalClipBounds() {
    final inverse = Matrix4.tryInvert(_s.ctm);
    if (inverse == null) return Rect.zero;
    return MatrixUtils.transformRect(inverse, _s.clip);
  }

  // ---------------------------------------------------------------------------
  // Recortes.

  void _intersectClip(Rect localBounds) {
    final device = MatrixUtils.transformRect(_s.ctm, localBounds);
    _s.clip = _s.clip.intersect(device);
    if (_s.clip.width < 0 || _s.clip.height < 0) _s.clip = Rect.zero;
  }

  @override
  void clipRect(Rect rect, {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    if (clipOp == ui.ClipOp.difference) {
      final big = getLocalClipBounds().inflate(1);
      _content
        ..rect(big.left, big.top, big.width, big.height)
        ..rect(rect.left, rect.top, rect.width, rect.height)
        ..clip(evenOdd: true);
      return;
    }
    _content
      ..rect(rect.left, rect.top, rect.width, rect.height)
      ..clip();
    _intersectClip(rect);
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _rrectPath(rrect);
    _content.clip();
    _intersectClip(rrect.outerRect);
  }

  @override
  void clipRSuperellipse(ui.RSuperellipse rsuperellipse, {bool doAntiAlias = true}) {
    clipPath(Path()..addRSuperellipse(rsuperellipse), doAntiAlias: doAntiAlias);
  }

  void clipOval(Rect rect) {
    _ellipse(rect);
    _content.clip();
    _intersectClip(rect);
  }

  /// Pinta um shading PDF (gradiente) na área de recorte atual.
  void paintShading(String name, PdfRef ref) {
    if (_s.alphaKey != null) {
      final gs = session.doc.extGState();
      _content.extGState(gs.name, gs.ref);
      _s.alphaKey = null;
    }
    _content.shading(name, ref);
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    _pathOps(path);
    _content.clip(evenOdd: path.fillType == PathFillType.evenOdd);
    _intersectClip(path.getBounds());
  }

  // ---------------------------------------------------------------------------
  // Paint → estado PDF.

  static bool _isSimplePaint(Paint paint, {bool allowShader = false}) =>
      (allowShader || paint.shader == null) &&
      paint.maskFilter == null &&
      paint.colorFilter == null &&
      paint.imageFilter == null &&
      !paint.invertColors &&
      _blendName(paint.blendMode) != null;

  static String? _blendName(BlendMode mode) => switch (mode) {
        BlendMode.srcOver || BlendMode.src => 'Normal',
        BlendMode.multiply => 'Multiply',
        BlendMode.screen => 'Screen',
        BlendMode.overlay => 'Overlay',
        BlendMode.darken => 'Darken',
        BlendMode.lighten => 'Lighten',
        BlendMode.colorDodge => 'ColorDodge',
        BlendMode.colorBurn => 'ColorBurn',
        BlendMode.hardLight => 'HardLight',
        BlendMode.softLight => 'SoftLight',
        BlendMode.difference => 'Difference',
        BlendMode.exclusion => 'Exclusion',
        BlendMode.hue => 'Hue',
        BlendMode.saturation => 'Saturation',
        BlendMode.color => 'Color',
        BlendMode.luminosity => 'Luminosity',
        _ => null,
      };

  static int _rgbKey(Color c) =>
      ((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round();

  void _applyAlpha(double alpha, BlendMode blendMode) {
    final blend = _blendName(blendMode) ?? 'Normal';
    final a = (alpha * 1000).round() / 1000;
    final key = '$a/$blend';
    if (_s.alphaKey == key || (_s.alphaKey == null && a == 1 && blend == 'Normal')) return;
    final gs = session.doc.extGState(
      fillAlpha: a,
      strokeAlpha: a,
      blendMode: blend == 'Normal' ? null : blend,
    );
    _content.extGState(gs.name, gs.ref);
    _s.alphaKey = key;
  }

  void _applyFill(Color color, {BlendMode blendMode = BlendMode.srcOver}) {
    final key = _rgbKey(color);
    if (_s.fill != key) {
      _content.fillRgb(color.r, color.g, color.b);
      _s.fill = key;
    }
    _applyAlpha(color.a, blendMode);
  }

  void _applyStroke(Paint paint) {
    final color = paint.color;
    final key = _rgbKey(color);
    if (_s.stroke != key) {
      _content.strokeRgb(color.r, color.g, color.b);
      _s.stroke = key;
    }
    _applyAlpha(color.a, paint.blendMode);
    if (_s.lineWidth != paint.strokeWidth) {
      _content.lineWidth(paint.strokeWidth);
      _s.lineWidth = paint.strokeWidth;
    }
    final cap = paint.strokeCap.index; // butt, round, square = 0, 1, 2
    if (_s.cap != cap) {
      _content.lineCap(cap);
      _s.cap = cap;
    }
    final join = switch (paint.strokeJoin) {
      StrokeJoin.miter => 0,
      StrokeJoin.round => 1,
      StrokeJoin.bevel => 2,
    };
    if (_s.join != join) {
      _content.lineJoin(join);
      _s.join = join;
    }
    if (join == 0 && _s.miter != paint.strokeMiterLimit) {
      _content.miterLimit(math.max(1, paint.strokeMiterLimit));
      _s.miter = paint.strokeMiterLimit;
    }
  }

  /// Emite o preenchimento ou traço do caminho já construído.
  void _paintPath(Paint paint, {bool evenOdd = false}) {
    if (paint.color.a == 0) {
      // Invisível (ex.: `Colors.transparent`): descarta o caminho.
      _content.endPath();
      return;
    }
    if (paint.style == PaintingStyle.stroke) {
      _applyStroke(paint);
      _content.stroke();
    } else {
      _applyFill(paint.color, blendMode: paint.blendMode);
      _content.fill(evenOdd: evenOdd);
    }
  }

  /// Se [local] (coordenadas locais) toca a área de recorte atual.
  bool isVisible(Rect local) => _isVisible(local);

  bool _isVisible(Rect local, [double inflate = 0]) {
    final device = MatrixUtils.transformRect(_s.ctm, local.inflate(inflate));
    return device.overlaps(_s.clip);
  }

  double get _deviceScale {
    final s = _s.ctm.storage;
    return math.sqrt((s[0] * s[5] - s[1] * s[4]).abs());
  }

  double _strokeInflate(Paint paint) =>
      paint.style == PaintingStyle.stroke ? paint.strokeWidth / 2 + paint.strokeMiterLimit : 0;

  /// Desenha fora do PDF (num `PictureRecorder`) e embute como imagem.
  void drawRasterized(Rect localBounds, void Function(ui.Canvas canvas) draw) {
    if (localBounds.isEmpty || !localBounds.isFinite) {
      final clip = getLocalClipBounds();
      localBounds = localBounds.isFinite ? localBounds.intersect(clip) : clip;
      if (localBounds.isEmpty) return;
    }
    final visible = localBounds.intersect(getLocalClipBounds().inflate(2));
    if (visible.width <= 0 || visible.height <= 0) return;

    var ratio = session.rasterPixelRatio * _deviceScale;
    const maxPixels = 4096.0;
    final longest = math.max(visible.width, visible.height) * ratio;
    if (longest > maxPixels) ratio *= maxPixels / longest;
    final w = math.max(1, (visible.width * ratio).ceil());
    final h = math.max(1, (visible.height * ratio).ceil());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..scale(w / visible.width, h / visible.height)
      ..translate(-visible.left, -visible.top);
    draw(canvas);
    final picture = recorder.endRecording();

    final image = session.doc.reserveImage();
    session.schedulePicture(image.ref, picture, w, h);
    _placeImage(image.name, image.ref, visible);
  }

  void _placeImage(String name, PdfRef ref, Rect dst) {
    _content
      ..save()
      ..transform(dst.width, 0, 0, -dst.height, dst.left, dst.bottom);
    // Imagens usam o alfa próprio (SMask); o alfa do estado é zerado.
    if (_s.alphaKey != null) {
      final gs = session.doc.extGState();
      _content.extGState(gs.name, gs.ref);
    }
    _content
      ..xObject(name, ref)
      ..restore();
  }

  // ---------------------------------------------------------------------------
  // Primitivas.

  @override
  void drawColor(Color color, BlendMode blendMode) {
    if (blendMode == BlendMode.clear || blendMode == BlendMode.dst) return;
    drawPaint(Paint()
      ..color = color
      ..blendMode = blendMode == BlendMode.src ? BlendMode.srcOver : blendMode);
  }

  @override
  void drawPaint(Paint paint) {
    final area = getLocalClipBounds();
    if (area.isEmpty) return;
    drawRect(area, Paint.from(paint)..style = PaintingStyle.fill);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    final bounds = Rect.fromPoints(p1, p2);
    if (!_isVisible(bounds, paint.strokeWidth + 1)) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(bounds.inflate(paint.strokeWidth + 1), (c) => c.drawLine(p1, p2, paint));
    }
    _content
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy);
    _applyStroke(paint);
    _content.stroke();
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    if (!_isVisible(rect, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(_paintBounds(rect, paint), (c) => c.drawRect(rect, paint));
    }
    _content.rect(rect.left, rect.top, rect.width, rect.height);
    _paintPath(paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    if (!_isVisible(rrect.outerRect, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(_paintBounds(rrect.outerRect, paint), (c) => c.drawRRect(rrect, paint));
    }
    _rrectPath(rrect);
    _paintPath(paint);
  }

  @override
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    if (!_isVisible(outer.outerRect, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(_paintBounds(outer.outerRect, paint), (c) => c.drawDRRect(outer, inner, paint));
    }
    _rrectPath(outer);
    _rrectPath(inner);
    _paintPath(paint, evenOdd: true);
  }

  @override
  void drawRSuperellipse(ui.RSuperellipse rsuperellipse, Paint paint) {
    drawPath(Path()..addRSuperellipse(rsuperellipse), paint);
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    if (!_isVisible(rect, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(_paintBounds(rect, paint), (c) => c.drawOval(rect, paint));
    }
    _ellipse(rect);
    _paintPath(paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    drawOval(Rect.fromCircle(center: c, radius: radius), paint);
  }

  @override
  void drawArc(Rect rect, double startAngle, double sweepAngle, bool useCenter, Paint paint) {
    if (!_isVisible(rect, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(
        _paintBounds(rect, paint),
        (c) => c.drawArc(rect, startAngle, sweepAngle, useCenter, paint),
      );
    }
    final center = rect.center;
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    final sweep = sweepAngle.clamp(-2 * math.pi, 2 * math.pi);
    final start = Offset(center.dx + rx * math.cos(startAngle), center.dy + ry * math.sin(startAngle));
    if (useCenter) {
      _content
        ..moveTo(center.dx, center.dy)
        ..lineTo(start.dx, start.dy);
    } else {
      _content.moveTo(start.dx, start.dy);
    }
    _arcSegments(center, rx, ry, startAngle, sweep);
    if (useCenter) _content.closePath();
    _paintPath(paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    final bounds = path.getBounds();
    if (!_isVisible(bounds, _strokeInflate(paint))) return;
    if (!_isSimplePaint(paint)) {
      return drawRasterized(_paintBounds(bounds, paint), (c) => c.drawPath(path, paint));
    }
    if (!_pathOps(path)) return;
    _paintPath(paint, evenOdd: path.fillType == PathFillType.evenOdd);
  }

  @override
  void drawPoints(ui.PointMode pointMode, List<Offset> points, Paint paint) {
    if (points.isEmpty) return;
    if (!_isSimplePaint(paint)) {
      var bounds = Rect.fromPoints(points.first, points.first);
      for (final p in points) {
        bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
      }
      return drawRasterized(
        bounds.inflate(paint.strokeWidth + 1),
        (c) => c.drawPoints(pointMode, points, paint),
      );
    }
    switch (pointMode) {
      case ui.PointMode.points:
        final r = paint.strokeWidth / 2;
        for (final p in points) {
          if (paint.strokeCap == StrokeCap.round) {
            _ellipse(Rect.fromCircle(center: p, radius: math.max(r, 0.25)));
          } else {
            final side = math.max(paint.strokeWidth, 0.5);
            _content.rect(p.dx - side / 2, p.dy - side / 2, side, side);
          }
        }
        _applyFill(paint.color, blendMode: paint.blendMode);
        _content.fill();
      case ui.PointMode.lines:
        for (var i = 0; i + 1 < points.length; i += 2) {
          _content
            ..moveTo(points[i].dx, points[i].dy)
            ..lineTo(points[i + 1].dx, points[i + 1].dy);
        }
        _applyStroke(paint);
        _content.stroke();
      case ui.PointMode.polygon:
        _content.moveTo(points.first.dx, points.first.dy);
        for (final p in points.skip(1)) {
          _content.lineTo(p.dx, p.dy);
        }
        _applyStroke(paint);
        _content.stroke();
    }
  }

  @override
  void drawRawPoints(ui.PointMode pointMode, Float32List points, Paint paint) {
    drawPoints(pointMode, [
      for (var i = 0; i + 1 < points.length; i += 2) Offset(points[i], points[i + 1]),
    ], paint);
  }

  Rect _paintBounds(Rect bounds, Paint paint) {
    var inflate = _strokeInflate(paint) + 1;
    final mask = paint.maskFilter;
    if (mask != null) inflate += 24;
    if (paint.imageFilter != null) inflate += 24;
    return bounds.inflate(inflate);
  }

  // ---------------------------------------------------------------------------
  // Imagens.

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) {
    drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(offset.dx, offset.dy, image.width.toDouble(), image.height.toDouble()),
      paint,
    );
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    if (!_isVisible(dst)) return;
    if (paint.colorFilter != null || paint.maskFilter != null || paint.imageFilter != null || paint.invertColors) {
      return drawRasterized(dst, (c) => c.drawImageRect(image, src, dst, paint));
    }
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final sx = dst.width / src.width;
    final sy = dst.height / src.height;
    final full = Rect.fromLTWH(dst.left - src.left * sx, dst.top - src.top * sy, w * sx, h * sy);
    final ref = session.imageFor(image);

    final cropped = src != Rect.fromLTWH(0, 0, w, h);
    final alpha = paint.color.a;
    if (cropped || alpha < 1) {
      _content.save();
      if (cropped) {
        _content
          ..rect(dst.left, dst.top, dst.width, dst.height)
          ..clip();
      }
      if (alpha < 1) {
        final gs = session.doc.extGState(fillAlpha: alpha, strokeAlpha: alpha);
        _content.extGState(gs.name, gs.ref);
      }
      _content
        ..transform(full.width, 0, 0, -full.height, full.left, full.bottom)
        ..xObject(ref.name, ref.ref)
        ..restore();
      return;
    }
    _placeImage(ref.name, ref.ref, full);
  }

  @override
  void drawImageNine(ui.Image image, Rect center, Rect dst, Paint paint) {
    if (!_isVisible(dst)) return;
    drawRasterized(dst, (c) => c.drawImageNine(image, center, dst, paint));
  }

  @override
  void drawPicture(ui.Picture picture) {
    drawRasterized(getLocalClipBounds(), (c) => c.drawPicture(picture));
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    // O conteúdo de um ui.Paragraph não é legível; vira imagem no lugar.
    final boxes = paragraph.getBoxesForRange(0, 1 << 30);
    if (boxes.isEmpty) return;
    var bounds = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      bounds = bounds.expandToInclude(box.toRect());
    }
    bounds = bounds.shift(offset).inflate(3);
    if (!_isVisible(bounds)) return;
    drawRasterized(bounds, (c) => c.drawParagraph(paragraph, offset));
  }

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) {
    drawRasterized(getLocalClipBounds(), (c) => c.drawVertices(vertices, blendMode, paint));
  }

  @override
  void drawAtlas(
    ui.Image atlas,
    List<RSTransform> transforms,
    List<Rect> rects,
    List<Color>? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    drawRasterized(
      cullRect ?? getLocalClipBounds(),
      (c) => c.drawAtlas(atlas, transforms, rects, colors, blendMode, cullRect, paint),
    );
  }

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    drawRasterized(
      cullRect ?? getLocalClipBounds(),
      (c) => c.drawRawAtlas(atlas, rstTransforms, rects, colors, blendMode, cullRect, paint),
    );
  }

  @override
  void drawShadow(Path path, Color color, double elevation, bool transparentOccluder) {
    final bounds = path.getBounds().inflate(elevation * 3 + 4).translate(0, elevation);
    if (!_isVisible(bounds)) return;
    drawRasterized(bounds, (c) => c.drawShadow(path, color, elevation, transparentOccluder));
  }

  // ---------------------------------------------------------------------------
  // Texto real (usado pelo emissor de parágrafos).

  /// Desenha glifos com a origem da linha de base em [origin] (coordenadas
  /// locais). [advances] são as posições x de cada glifo relativas à origem.
  void drawGlyphRun({
    required EmbeddedFont font,
    required double fontSize,
    required Offset origin,
    required List<int> glyphs,
    required List<double> positions,
    required Color color,
    double skewX = 0,
    bool fakeBold = false,
  }) {
    if (glyphs.isEmpty) return;
    _applyFill(color);
    if (fakeBold) {
      final strokeColor = _rgbKey(color);
      if (_s.stroke != strokeColor) {
        _content.strokeRgb(color.r, color.g, color.b);
        _s.stroke = strokeColor;
      }
      final width = fontSize / 30;
      if (_s.lineWidth != width) {
        _content.lineWidth(width);
        _s.lineWidth = width;
      }
    }
    _content
      ..beginText()
      ..font(font.resourceName, font.ref, fontSize);
    if (fakeBold) _content.textRenderMode(2);
    final base = positions[0];
    _content.textMatrix(1, 0, skewX, -1, origin.dx + base, origin.dy);

    // Ajustes TJ para colocar cada glifo exatamente na posição do layout.
    final adjustments = List<double>.filled(glyphs.length, 0);
    var pen = 0.0;
    for (var i = 0; i < glyphs.length; i++) {
      final expected = positions[i] - base;
      if (i > 0) adjustments[i - 1] = (pen - expected) * 1000 / fontSize;
      pen = expected + font.font.advance1000(glyphs[i]) * fontSize / 1000;
    }
    _content.showGlyphsAdjusted(glyphs, adjustments);
    if (fakeBold) _content.textRenderMode(0);
    _content.endText();
  }

  /// Desenha glifos de fontes CFF como caminhos preenchidos (sem texto
  /// selecionável; usado principalmente para ícones).
  void drawGlyphOutlines({
    required TtfFont font,
    required double fontSize,
    required Offset origin,
    required List<int> glyphs,
    required List<double> positions,
    required Color color,
    double skewX = 0,
  }) {
    final outlines = font.cffOutlines;
    if (outlines == null || glyphs.isEmpty) return;
    final scale = fontSize / font.unitsPerEm;
    var any = false;
    for (var i = 0; i < glyphs.length; i++) {
      final outline = outlines.glyph(glyphs[i]);
      if (outline.isEmpty) continue;
      final ox = origin.dx + positions[i];
      final oy = origin.dy;
      final c = outline.coords;
      var k = 0;
      double px(int j) => ox + (c[j] + skewX * c[j + 1]) * scale;
      double py(int j) => oy - c[j + 1] * scale;
      for (final command in outline.commands) {
        switch (command) {
          case 0:
            _content.moveTo(px(k), py(k));
            k += 2;
          case 1:
            _content.lineTo(px(k), py(k));
            k += 2;
          case 2:
            _content.curveTo(px(k), py(k), px(k + 2), py(k + 2), px(k + 4), py(k + 4));
            k += 6;
          default:
            _content.closePath();
        }
      }
      any = true;
    }
    if (!any) return;
    _applyFill(color);
    _content.fill();
  }

  // ---------------------------------------------------------------------------
  // Geometria.

  static const _kappa = 0.5522847498;

  void _ellipse(Rect r) {
    final cx = r.center.dx;
    final cy = r.center.dy;
    final rx = r.width / 2;
    final ry = r.height / 2;
    final ox = rx * _kappa;
    final oy = ry * _kappa;
    _content
      ..moveTo(cx + rx, cy)
      ..curveTo(cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry)
      ..curveTo(cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy)
      ..curveTo(cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry)
      ..curveTo(cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy)
      ..closePath();
  }

  void _rrectPath(RRect r) {
    if (r.isRect) {
      _content.rect(r.left, r.top, r.width, r.height);
      return;
    }
    final c = _content;
    c.moveTo(r.left + r.tlRadiusX, r.top);
    c.lineTo(r.right - r.trRadiusX, r.top);
    c.curveTo(
      r.right - r.trRadiusX * (1 - _kappa), r.top, //
      r.right, r.top + r.trRadiusY * (1 - _kappa),
      r.right, r.top + r.trRadiusY,
    );
    c.lineTo(r.right, r.bottom - r.brRadiusY);
    c.curveTo(
      r.right, r.bottom - r.brRadiusY * (1 - _kappa), //
      r.right - r.brRadiusX * (1 - _kappa), r.bottom,
      r.right - r.brRadiusX, r.bottom,
    );
    c.lineTo(r.left + r.blRadiusX, r.bottom);
    c.curveTo(
      r.left + r.blRadiusX * (1 - _kappa), r.bottom, //
      r.left, r.bottom - r.blRadiusY * (1 - _kappa),
      r.left, r.bottom - r.blRadiusY,
    );
    c.lineTo(r.left, r.top + r.tlRadiusY);
    c.curveTo(
      r.left, r.top + r.tlRadiusY * (1 - _kappa), //
      r.left + r.tlRadiusX * (1 - _kappa), r.top,
      r.left + r.tlRadiusX, r.top,
    );
    c.closePath();
  }

  /// Arco elíptico aproximado por Béziers de no máximo 90°.
  void _arcSegments(Offset center, double rx, double ry, double start, double sweep) {
    final segments = math.max(1, (sweep.abs() / (math.pi / 2)).ceil());
    final delta = sweep / segments;
    final k = 4 / 3 * math.tan(delta / 4);
    var a = start;
    for (var i = 0; i < segments; i++) {
      final b = a + delta;
      final cosA = math.cos(a), sinA = math.sin(a);
      final cosB = math.cos(b), sinB = math.sin(b);
      _content.curveTo(
        center.dx + rx * (cosA - k * sinA),
        center.dy + ry * (sinA + k * cosA),
        center.dx + rx * (cosB + k * sinB),
        center.dy + ry * (sinB - k * cosB),
        center.dx + rx * cosB,
        center.dy + ry * sinB,
      );
      a = b;
    }
  }

  /// Converte um [Path] (opaco no Flutter) em segmentos de reta, amostrando
  /// o contorno com subdivisão adaptativa. Retorna falso se estiver vazio.
  bool _pathOps(Path path) {
    // As métricas do Flutter percorrem o caminho sobre uma aproximação
    // poligonal com tolerância de 0,5 unidade. Medindo o caminho ampliado,
    // essa tolerância cai para ~0,03 unidade na escala original.
    const upscale = 16.0;
    final measured = path.transform(Matrix4.diagonal3Values(upscale, upscale, 1).storage);
    // Tolerância (na escala ampliada) equivalente a ~0,02 pt no dispositivo.
    final tolerance = upscale * 0.02 / math.max(_deviceScale, 1e-6);
    Offset down(Offset p) => p / upscale;

    var any = false;
    final metrics = measured.computeMetrics().toList();
    for (final metric in metrics) {
      final length = metric.length;
      if (length <= 0) continue;
      final start = metric.getTangentForOffset(0)!.position;
      final end = metric.getTangentForOffset(length)!.position;

      // Contorno reto (ex.: linhas de TableBorder): um único segmento.
      if (!metric.isClosed && (length - (end - start).distance).abs() <= tolerance * 0.05) {
        final a = down(start), b = down(end);
        if (metrics.length > 1 && !_isVisible(Rect.fromPoints(a, b), 1)) continue;
        _content
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
        any = true;
        continue;
      }
      // Em caminhos com muitos contornos, ignora os que estão fora da página.
      if (metrics.length > 1) {
        final bounds = metric.extractPath(0, length).getBounds();
        if (!_isVisible(Rect.fromPoints(down(bounds.topLeft), down(bounds.bottomRight)), 1)) continue;
      }

      final points = <Offset>[start];
      // Divisão inicial grossa; a subdivisão adaptativa refina só onde há
      // curvas ou cantos.
      final initial = math.max(4, (length / (256 * upscale)).ceil());
      var prevT = 0.0;
      var prevP = start;
      for (var i = 1; i <= initial; i++) {
        final t = length * i / initial;
        final p = metric.getTangentForOffset(t)!.position;
        _subdivide(metric, prevT, prevP, t, p, tolerance, 0, points);
        prevT = t;
        prevP = p;
      }

      final simplified = _simplify(points, tolerance);
      final first = down(simplified.first);
      _content.moveTo(first.dx, first.dy);
      for (final p in simplified.skip(1)) {
        final q = down(p);
        _content.lineTo(q.dx, q.dy);
      }
      if (metric.isClosed) _content.closePath();
      any = true;
    }
    return any;
  }

  void _subdivide(
    ui.PathMetric metric,
    double t0,
    Offset p0,
    double t1,
    Offset p1,
    double tolerance,
    int depth,
    List<Offset> out,
  ) {
    final span = t1 - t0;
    final chord = (p1 - p0).distance;
    // Trecho reto: o comprimento do arco é igual à corda.
    if (depth >= 28 || span <= tolerance || span - chord <= tolerance * 0.05) {
      out.add(p1);
      return;
    }
    final tm = (t0 + t1) / 2;
    final pm = metric.getTangentForOffset(tm)!.position;
    final deviation = _distanceToSegment(pm, p0, p1);
    if (deviation <= tolerance && span - chord <= tolerance) {
      out.add(p1);
      return;
    }
    _subdivide(metric, t0, p0, tm, pm, tolerance, depth + 1, out);
    _subdivide(metric, tm, pm, t1, p1, tolerance, depth + 1, out);
  }

  /// Remove pontos intermediários alinhados (tempo linear): estende a reta
  /// a partir de uma âncora enquanto os pontos seguintes ficam sobre ela.
  static List<Offset> _simplify(List<Offset> points, double tolerance) {
    if (points.length <= 2) return points;
    final result = <Offset>[points.first];
    var anchor = points.first;
    Offset? direction;
    var directionLength = 0.0;
    var progress = 0.0;
    for (var i = 1; i < points.length; i++) {
      final p = points[i];
      final d = p - anchor;
      if (direction == null) {
        final length = d.distance;
        if (length == 0) continue;
        direction = d;
        directionLength = length;
        progress = length;
        continue;
      }
      final along = (d.dx * direction.dx + d.dy * direction.dy) / directionLength;
      final across = (d.dx * direction.dy - d.dy * direction.dx).abs() / directionLength;
      if (across <= tolerance * 0.5 && along >= progress) {
        progress = along;
        continue;
      }
      final corner = points[i - 1];
      result.add(corner);
      anchor = corner;
      final next = p - anchor;
      directionLength = next.distance;
      direction = directionLength == 0 ? null : next;
      progress = directionLength;
    }
    if (result.last != points.last) result.add(points.last);
    return result;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}
