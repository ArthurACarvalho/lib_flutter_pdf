import 'dart:ui' as ui;

import '../core/document_builder.dart';
import '../core/objects.dart';
import '../font/font_registry.dart';

/// Trabalho assíncrono pendente (ex.: ler pixels de uma imagem) cujo
/// resultado preenche um objeto já referenciado pelo conteúdo da página.
class PdfAssetJob {
  PdfAssetJob(this._run, this._cancel);

  final Future<void> Function() _run;
  final void Function() _cancel;

  Future<void> run() => _run();

  void cancel() => _cancel();
}

/// Estado compartilhado por toda a geração de um documento.
class PdfRenderSession {
  PdfRenderSession({required this.doc, required this.fonts, this.rasterPixelRatio = 3});

  final PdfDocumentBuilder doc;
  final FontRegistry fonts;

  /// Resolução (pixels por ponto) dos trechos que precisam virar imagem.
  final double rasterPixelRatio;

  final List<PdfAssetJob> _jobs = [];

  // Imagens já registradas: a mesma imagem (ex.: logo no cabeçalho de todas
  // as páginas) vira um único XObject.
  final List<(ui.Image, PdfNamedRef)> _images = [];

  /// XObject para [image], reaproveitando o de uma imagem idêntica.
  PdfNamedRef imageFor(ui.Image image) {
    for (final (known, ref) in _images) {
      if (known.isCloneOf(image)) return ref;
    }
    // Gravadas em runJobs, fora da lista de rollback: o mesmo XObject pode
    // ser referenciado por conteúdos que não foram desfeitos.
    final ref = doc.reserveImage();
    _images.add((image.clone(), ref));
    return ref;
  }

  int get jobCount => _jobs.length;

  /// Descarta trabalhos criados depois de [count] (conteúdo desfeito).
  void rollbackJobs(int count) {
    while (_jobs.length > count) {
      _jobs.removeLast().cancel();
    }
  }

  /// Agenda a gravação de uma imagem do Flutter no XObject [ref].
  void scheduleImage(PdfRef ref, ui.Image image) {
    _jobs.add(
      PdfAssetJob(
        () async {
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
            doc.setImageRgba(ref, image.width, image.height, data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        },
        () {
          image.dispose();
          doc.writer.set(ref, const PdfNull());
        },
      ),
    );
  }

  /// Agenda a rasterização de um [ui.Picture] com [width]x[height] pixels.
  void schedulePicture(PdfRef ref, ui.Picture picture, int width, int height) {
    _jobs.add(
      PdfAssetJob(
        () async {
          try {
            final image = await picture.toImage(width, height);
            try {
              final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
              doc.setImageRgba(ref, width, height, data!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          } finally {
            picture.dispose();
          }
        },
        () {
          picture.dispose();
          doc.writer.set(ref, const PdfNull());
        },
      ),
    );
  }

  /// Agenda um trabalho genérico (ex.: rasterizar uma layer).
  void scheduleJob(Future<void> Function() run, void Function() cancel) {
    _jobs.add(PdfAssetJob(run, cancel));
  }

  Future<void> runJobs() async {
    // Processa em ordem; cada job libera sua memória ao terminar.
    for (var i = 0; i < _jobs.length; i++) {
      await _jobs[i].run();
    }
    _jobs.clear();
    for (final (image, ref) in _images) {
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        doc.setImageRgba(ref.ref, image.width, image.height, data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    _images.clear();
  }
}
