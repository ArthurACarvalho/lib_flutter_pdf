import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../widgets/markers.dart';

const _eps = 0.01;

/// Cabeçalho de tabela que se repete nas páginas de continuação.
class RepeatHeaderRegion {
  RepeatHeaderRegion({required this.headerTop, required this.headerBottom, required this.bottom});

  /// Faixa do cabeçalho em coordenadas da raiz.
  final double headerTop;
  final double headerBottom;

  /// Fim da tabela.
  final double bottom;

  double get headerHeight => headerBottom - headerTop;
}

/// Análise de uma árvore já com layout: onde ela pode ser cortada entre
/// páginas sem atravessar conteúdo.
class BreakAnalysis {
  BreakAnalysis._(this.height, this.breaks, this.forcedBreaks, this.repeatHeaders);

  factory BreakAnalysis.of(RenderBox root) {
    final finder = _Finder();
    final breaks = finder.breaksOf(root, 0);
    return BreakAnalysis._(
      root.size.height,
      breaks,
      finder.forced..sort(),
      finder.headers..sort((a, b) => a.headerTop.compareTo(b.headerTop)),
    );
  }

  final double height;

  /// Pontos de corte válidos, em ordem crescente.
  final List<double> breaks;

  /// Posições de `PdfPageBreak`.
  final List<double> forcedBreaks;

  final List<RepeatHeaderRegion> repeatHeaders;

  /// Maior ponto de corte em (after, limit].
  double? lastBreakIn(double after, double limit) {
    var lo = 0;
    var hi = breaks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (breaks[mid] <= limit + _eps) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final index = lo - 1;
    if (index >= 0 && breaks[index] > after + _eps) return breaks[index];
    return null;
  }

  /// Primeira quebra forçada em (after, limit].
  double? forcedBreakIn(double after, double limit) {
    for (final b in forcedBreaks) {
      if (b > after + _eps && b <= limit + _eps) return b;
      if (b > limit) break;
    }
    return null;
  }

  /// Cabeçalho repetido aplicável a um corte que começa em [y].
  RepeatHeaderRegion? headerFor(double y) {
    for (final region in repeatHeaders.reversed) {
      if (y > region.headerBottom + _eps && y < region.bottom - _eps) return region;
    }
    return null;
  }
}

class _Finder {
  final List<double> forced = [];
  final List<RepeatHeaderRegion> headers = [];

  /// Pontos de corte internos de [node], cujo topo está em [top] (raiz).
  List<double> breaksOf(RenderObject node, double top) {
    if (node is! RenderBox || !node.hasSize) return const [];
    final bottom = top + node.size.height;

    if (node is RenderPdfPageBreak) {
      forced.add(top);
      return const [];
    }
    if (node is RenderPdfKeepTogether || node is RenderPdfRasterize) {
      _collectMarkers(node, top);
      return const [];
    }
    if (node is RenderParagraph) return _paragraphBreaks(node, top);
    if (node is RenderPdfRepeatHeader) _registerHeader(node, top);
    if (node is RenderTable) return _tableBreaks(node, top);

    final children = <_Child>[];
    node.visitChildren((child) {
      if (child is! RenderBox || !child.hasSize) return;
      final transform = Matrix4.identity();
      node.applyPaintTransform(child, transform);
      final dy = _translationY(transform);
      if (dy == null) {
        // Rotação/escala: não dá para garantir cortes internos.
        final rect = MatrixUtils.transformRect(transform, Offset.zero & child.size);
        children.add(_Child(top + rect.top, top + rect.bottom, const []));
        _collectMarkers(child, top + rect.top);
        return;
      }
      final childTop = top + dy;
      children.add(_Child(childTop, childTop + child.size.height, breaksOf(child, childTop)));
    });
    if (children.isEmpty) return const [];

    // Candidatos: bordas e cortes internos dos filhos.
    final candidates = <double>{};
    for (final child in children) {
      candidates
        ..add(child.top)
        ..add(child.bottom)
        ..addAll(child.breaks);
    }
    final sortedCandidates = candidates.where((y) => y > top + _eps && y < bottom - _eps).toList()..sort();
    if (sortedCandidates.isEmpty) return const [];

    children.sort((a, b) => a.top.compareTo(b.top));
    final maxBottom = List<double>.filled(children.length, 0);
    var running = double.negativeInfinity;
    for (var i = 0; i < children.length; i++) {
      if (children[i].bottom > running) running = children[i].bottom;
      maxBottom[i] = running;
    }

    final result = <double>[];
    for (final y in sortedCandidates) {
      if (_validFor(y, children, maxBottom)) result.add(y);
    }
    return result;
  }

  bool _validFor(double y, List<_Child> children, List<double> maxBottom) {
    // Último filho que começa antes de y.
    var lo = 0;
    var hi = children.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (children[mid].top < y - _eps) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    for (var i = lo - 1; i >= 0; i--) {
      if (maxBottom[i] <= y + _eps) break;
      final child = children[i];
      if (child.bottom > y + _eps && !_contains(child.breaks, y)) return false;
    }
    return true;
  }

  static bool _contains(List<double> sorted, double y) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid] < y - _eps) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < sorted.length && (sorted[lo] - y).abs() <= _eps;
  }

  static double? _translationY(Matrix4 m) {
    final s = m.storage;
    const tolerance = 1e-9;
    final identityLinear = (s[0] - 1).abs() < tolerance &&
        s[1].abs() < tolerance &&
        s[4].abs() < tolerance &&
        (s[5] - 1).abs() < tolerance;
    return identityLinear ? s[13] : null;
  }

  List<double> _paragraphBreaks(RenderParagraph paragraph, double top) {
    final length = paragraph.text.toPlainText(includeSemanticsLabels: false).length;
    if (length == 0) return const [];
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: length),
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    final lineBottoms = <double>{for (final box in boxes) box.bottom};
    // Widgets embutidos no texto também não podem ser cortados.
    final blocked = <(double, double)>[];
    var child = paragraph.firstChild;
    while (child != null) {
      final data = child.parentData! as TextParentData;
      final offset = data.offset;
      if (offset != null) blocked.add((offset.dy, offset.dy + child.size.height));
      _collectMarkers(child, top + (offset?.dy ?? 0));
      child = data.nextSibling;
    }
    final height = paragraph.size.height;
    return [
      for (final y in lineBottoms.toList()..sort())
        if (y > _eps && y < height - _eps && !blocked.any((b) => y > b.$1 + _eps && y < b.$2 - _eps)) top + y,
    ];
  }

  List<double> _tableBreaks(RenderTable table, double top) {
    final result = <double>[];
    for (var row = 0; row < table.rows; row++) {
      final box = table.getRowBox(row);
      if (row > 0) result.add(top + box.top);
      // Marcadores dentro das células (quebras forçadas, cabeçalhos).
    }
    table.visitChildren((cell) {
      if (cell is RenderBox && cell.hasSize) {
        final data = cell.parentData;
        final dy = data is BoxParentData ? data.offset.dy : 0.0;
        _collectMarkers(cell, top + dy);
      }
    });
    return result.where((y) => y > top + _eps && y < top + table.size.height - _eps).toList();
  }

  void _registerHeader(RenderPdfRepeatHeader marker, double top) {
    final table = marker.table;
    if (table == null || table.rows <= marker.headerRows) return;
    // Posição da tabela dentro do marcador.
    final transform = table.getTransformTo(marker);
    final tableTop = top + (_translationY(transform) ?? 0);
    final first = table.getRowBox(0);
    final last = table.getRowBox(marker.headerRows - 1);
    headers.add(RepeatHeaderRegion(
      headerTop: tableTop + first.top,
      headerBottom: tableTop + last.bottom,
      bottom: tableTop + table.size.height,
    ));
  }

  /// Registra quebras forçadas e cabeçalhos dentro de subárvores atômicas.
  void _collectMarkers(RenderObject node, double top) {
    node.visitChildren((child) {
      if (child is! RenderBox || !child.hasSize) return;
      final transform = Matrix4.identity();
      node.applyPaintTransform(child, transform);
      final childTop = top + (_translationY(transform) ?? 0);
      if (child is RenderPdfPageBreak) forced.add(childTop);
      _collectMarkers(child, childTop);
    });
  }
}

class _Child {
  _Child(this.top, this.bottom, this.breaks);

  final double top;
  final double bottom;
  final List<double> breaks;
}
