import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../widgets/markers.dart';
import 'gradient_painter.dart';
import 'paragraph_emitter.dart';
import 'pdf_canvas.dart';

/// [PaintingContext] que pinta a árvore de render objects diretamente no
/// [PdfCanvas], sem criar layers de composição.
///
/// Subárvores que dependem de efeitos sem equivalente vetorial (filtros,
/// shader masks, texturas) são detectadas e substituídas por uma imagem.
class VectorPaintingContext extends PaintingContext {
  VectorPaintingContext(this.pdfCanvas, Rect estimatedBounds)
      : _paragraphs = ParagraphEmitter(pdfCanvas),
        super(ContainerLayer(), estimatedBounds);

  final PdfCanvas pdfCanvas;
  final ParagraphEmitter _paragraphs;

  @override
  Canvas get canvas => pdfCanvas;

  /// Pinta [root] (já com layout) em [offset].
  void paintRoot(RenderObject root, Offset offset) => paintChild(root, offset);

  @override
  void paintChild(RenderObject child, Offset offset) {
    if (child is RenderBox && !child.hasSize) return;

    // Descarta o que está totalmente fora da área visível (ex.: linhas de
    // uma tabela que pertencem a outra página).
    final bounds = child.paintBounds.shift(offset);
    if (bounds.isFinite && !_isVisible(bounds)) return;

    if (child is RenderPdfRasterize) {
      _rasterize(child, offset, child.pixelRatio);
      return;
    }

    final checkpoint = pdfCanvas.checkpoint();
    final wasUnsupported = pdfCanvas.unsupported;
    pdfCanvas.unsupported = false;

    // Repaint boundaries aplicam efeitos (ex.: RenderOpacity) pela layer que
    // devolvem em updateCompositedLayer, e não durante o paint.
    var groupAlpha = 1.0;
    if (child.isRepaintBoundary) {
      // ignore: invalid_use_of_protected_member
      final layer = child.updateCompositedLayer(oldLayer: null);
      if (layer is OpacityLayer) {
        groupAlpha = (layer.alpha ?? 255) / 255;
      } else if (layer.runtimeType != OffsetLayer) {
        pdfCanvas.unsupported = true;
      }
      layer.dispose();
      if (groupAlpha <= 0) {
        pdfCanvas.unsupported = wasUnsupported;
        return;
      }
      if (groupAlpha < 1) {
        pdfCanvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, groupAlpha));
      }
    }

    if (pdfCanvas.unsupported) {
      // Nada a pintar: a subárvore inteira vira imagem logo abaixo.
    } else if (child is RenderParagraph) {
      if (!_paragraphs.emit(this, child, offset)) child.paint(this, offset);
    } else if (child is RenderDecoratedBox) {
      if (!paintGradientDecoration(this, child, offset)) child.paint(this, offset);
    } else {
      child.paint(this, offset);
    }
    if (groupAlpha < 1) pdfCanvas.restore();

    if (pdfCanvas.unsupported) {
      pdfCanvas.rollback(checkpoint);
      _rasterize(child, offset, null);
    }
    pdfCanvas.unsupported = wasUnsupported;
  }

  bool _isVisible(Rect local) {
    final device = MatrixUtils.transformRect(pdfCanvas.currentTransform, local);
    return device.overlaps(pdfCanvas.deviceClipBounds);
  }

  /// Pinta [child] com o pipeline normal do Flutter e embute como imagem.
  void _rasterize(RenderObject child, Offset offset, double? pixelRatio) {
    final bounds = child.paintBounds;
    if (bounds.isEmpty || !bounds.isFinite) return;
    final layer = OffsetLayer();
    final context = _LayerPaintingContext(layer, bounds);
    context.paintChild(child, Offset.zero);
    context.finish();

    final session = pdfCanvas.session;
    final m = pdfCanvas.currentTransform.storage;
    final deviceScale = math.sqrt((m[0] * m[5] - m[1] * m[4]).abs());
    var ratio = (pixelRatio ?? session.rasterPixelRatio) * deviceScale;
    const maxPixels = 4096.0;
    final longest = math.max(bounds.width, bounds.height) * ratio;
    if (longest > maxPixels) ratio *= maxPixels / longest;

    final image = session.doc.reserveImage();
    session.scheduleJob(
      () async {
        try {
          final rendered = await layer.toImage(bounds, pixelRatio: ratio);
          try {
            final data = await rendered.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
            session.doc.setImageRgba(image.ref, rendered.width, rendered.height, data!.buffer.asUint8List());
          } finally {
            rendered.dispose();
          }
        } finally {
          layer.dispose();
        }
      },
      () => layer.dispose(),
    );
    final dst = bounds.shift(offset);
    pdfCanvas.content
      ..save()
      ..transform(dst.width, 0, 0, -dst.height, dst.left, dst.bottom)
      ..xObject(image.name, image.ref)
      ..restore();
  }

  // Composição é sempre achatada no canvas.

  @override
  ClipRectLayer? pushClipRect(
    bool needsCompositing,
    Offset offset,
    Rect clipRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.hardEdge,
    ClipRectLayer? oldLayer,
  }) {
    return super.pushClipRect(false, offset, clipRect, painter, clipBehavior: clipBehavior);
  }

  @override
  ClipRRectLayer? pushClipRRect(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RRect clipRRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRRectLayer? oldLayer,
  }) {
    return super.pushClipRRect(false, offset, bounds, clipRRect, painter, clipBehavior: clipBehavior);
  }

  @override
  ClipRSuperellipseLayer? pushClipRSuperellipse(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RSuperellipse clipRSuperellipse,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRSuperellipseLayer? oldLayer,
  }) {
    return super.pushClipRSuperellipse(
      false,
      offset,
      bounds,
      clipRSuperellipse,
      painter,
      clipBehavior: clipBehavior,
    );
  }

  @override
  ClipPathLayer? pushClipPath(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    Path clipPath,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipPathLayer? oldLayer,
  }) {
    return super.pushClipPath(false, offset, bounds, clipPath, painter, clipBehavior: clipBehavior);
  }

  @override
  TransformLayer? pushTransform(
    bool needsCompositing,
    Offset offset,
    Matrix4 transform,
    PaintingContextCallback painter, {
    TransformLayer? oldLayer,
  }) {
    return super.pushTransform(false, offset, transform, painter);
  }

  @override
  void pushLayer(
    ContainerLayer childLayer,
    PaintingContextCallback painter,
    Offset offset, {
    Rect? childPaintBounds,
  }) {
    switch (childLayer) {
      case OpacityLayer(:final alpha, offset: final layerOffset):
        final a = (alpha ?? 255) / 255;
        if (a <= 0) return;
        pdfCanvas.save();
        pdfCanvas.translate(layerOffset.dx, layerOffset.dy);
        if (a < 1) {
          pdfCanvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, a));
        }
        painter(this, offset);
        if (a < 1) pdfCanvas.restore();
        pdfCanvas.restore();
      case ClipRectLayer(:final clipRect?, :final clipBehavior):
        clipRectAndPaint(clipRect, clipBehavior, clipRect, () => painter(this, offset));
      case ClipRRectLayer(:final clipRRect?, :final clipBehavior):
        clipRRectAndPaint(clipRRect, clipBehavior, clipRRect.outerRect, () => painter(this, offset));
      case ClipPathLayer(:final clipPath?, :final clipBehavior):
        clipPathAndPaint(clipPath, clipBehavior, clipPath.getBounds(), () => painter(this, offset));
      case TransformLayer(:final transform?, offset: final layerOffset):
        pdfCanvas.save();
        pdfCanvas.translate(layerOffset.dx, layerOffset.dy);
        pdfCanvas.transform(transform.storage);
        painter(this, offset);
        pdfCanvas.restore();
      case ColorFilterLayer() ||
            ImageFilterLayer() ||
            ShaderMaskLayer() ||
            BackdropFilterLayer() ||
            FollowerLayer():
        pdfCanvas.unsupported = true;
      case OffsetLayer(offset: final layerOffset):
        pdfCanvas.save();
        pdfCanvas.translate(layerOffset.dx, layerOffset.dy);
        painter(this, offset);
        pdfCanvas.restore();
      default:
        // Layers sem efeito visual (anotações, líderes etc.).
        painter(this, offset);
    }
  }

  @override
  void addLayer(Layer layer) {
    // Texturas, platform views e afins não têm como ser lidas aqui.
    pdfCanvas.unsupported = true;
  }

  @override
  void setIsComplexHint() {}

  @override
  void setWillChangeHint() {}

  @override
  PaintingContext createChildContext(ContainerLayer childLayer, Rect bounds) => this;
}

/// Contexto de pintura normal, usado para rasterizar subárvores.
class _LayerPaintingContext extends PaintingContext {
  _LayerPaintingContext(super.containerLayer, super.estimatedBounds);

  void finish() => stopRecordingIfNeeded();
}
