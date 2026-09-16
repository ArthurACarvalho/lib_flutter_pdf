import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Força [child] a virar imagem no PDF (útil para widgets com efeitos que
/// não têm equivalente vetorial ou que ficam pesados como vetor).
class PdfRasterize extends SingleChildRenderObjectWidget {
  const PdfRasterize({super.key, this.pixelRatio, required Widget super.child});

  /// Pixels por ponto. Padrão: o `rasterPixelRatio` do documento.
  final double? pixelRatio;

  @override
  RenderPdfRasterize createRenderObject(BuildContext context) => RenderPdfRasterize(pixelRatio);

  @override
  void updateRenderObject(BuildContext context, RenderPdfRasterize renderObject) {
    renderObject.pixelRatio = pixelRatio;
  }
}

class RenderPdfRasterize extends RenderProxyBox {
  RenderPdfRasterize(this.pixelRatio);

  double? pixelRatio;
}

/// Impede que a paginação corte [child] ao meio: se não couber no espaço
/// restante, ele começa na próxima página.
class PdfKeepTogether extends SingleChildRenderObjectWidget {
  const PdfKeepTogether({super.key, required Widget super.child});

  @override
  RenderPdfKeepTogether createRenderObject(BuildContext context) => RenderPdfKeepTogether();
}

class RenderPdfKeepTogether extends RenderProxyBox {}

/// Força uma quebra de página antes do próximo conteúdo.
///
/// Funciona em qualquer nível da árvore de um `PdfMultiPage` (inclusive
/// dentro de `Column`s aninhadas).
class PdfPageBreak extends LeafRenderObjectWidget {
  const PdfPageBreak({super.key});

  @override
  RenderPdfPageBreak createRenderObject(BuildContext context) => RenderPdfPageBreak();
}

class RenderPdfPageBreak extends RenderBox {
  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => constraints.smallest;
}

/// Marca uma `Table` cuja primeira linha é cabeçalho e deve ser repetida no
/// topo de cada página em que a tabela continuar. Criado por `PdfTable`.
class PdfRepeatHeader extends SingleChildRenderObjectWidget {
  const PdfRepeatHeader({super.key, this.headerRows = 1, required Widget super.child});

  final int headerRows;

  @override
  RenderPdfRepeatHeader createRenderObject(BuildContext context) => RenderPdfRepeatHeader(headerRows);

  @override
  void updateRenderObject(BuildContext context, RenderPdfRepeatHeader renderObject) {
    renderObject.headerRows = headerRows;
  }
}

class RenderPdfRepeatHeader extends RenderProxyBox {
  RenderPdfRepeatHeader(this.headerRows);

  int headerRows;

  /// A tabela interna (primeiro `RenderTable` descendente).
  RenderTable? get table {
    RenderTable? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderTable) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visitChildren(visit);
    return found;
  }
}
