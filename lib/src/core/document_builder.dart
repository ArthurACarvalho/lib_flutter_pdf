import 'dart:typed_data';

import '../font/embedded_font.dart';
import '../font/ttf_parser.dart';
import 'content.dart';
import 'objects.dart';
import 'writer.dart';

/// Recurso nomeado já registrado no documento.
typedef PdfNamedRef = ({String name, PdfRef ref});

/// Metadados do arquivo.
class PdfInfo {
  const PdfInfo({this.title, this.author, this.subject, this.keywords, this.creator});

  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;
  final String? creator;
}

/// Acumula páginas e recursos compartilhados e produz os bytes do PDF.
class PdfDocumentBuilder {
  final PdfWriter writer = PdfWriter();
  final List<PdfRef> _pages = [];
  late final PdfRef _pagesRef = writer.reserve();

  final Map<TtfFont, EmbeddedFont> _fonts = {};
  final Map<String, PdfNamedRef> _extGStates = {};
  int _imageCount = 0;
  int _formCount = 0;
  int _shadingCount = 0;

  EmbeddedFont font(TtfFont font) => _fonts.putIfAbsent(
    font,
    () => EmbeddedFont(font: font, resourceName: 'F${_fonts.length + 1}', ref: writer.reserve()),
  );

  /// Estado gráfico com opacidade de preenchimento/traço.
  PdfNamedRef extGState({double fillAlpha = 1, double strokeAlpha = 1, String? blendMode}) {
    final ca = (fillAlpha * 1000).round() / 1000;
    final sa = (strokeAlpha * 1000).round() / 1000;
    final key = '$ca/$sa/$blendMode';
    return _extGStates.putIfAbsent(key, () {
      final ref = writer.add(
        PdfDict({
          'Type': const PdfName('ExtGState'),
          'ca': PdfNum(ca),
          'CA': PdfNum(sa),
          if (blendMode != null) 'BM': PdfName(blendMode),
        }),
      );
      return (name: 'G${_extGStates.length + 1}', ref: ref);
    });
  }

  /// Reserva um XObject de imagem cujo conteúdo será definido depois
  /// (as imagens do Flutter só podem ser lidas de forma assíncrona).
  PdfNamedRef reserveImage() => (name: 'Im${++_imageCount}', ref: writer.reserve());

  void setImageRgba(PdfRef ref, int width, int height, Uint8List rgba) {
    final pixels = width * height;
    final rgb = Uint8List(pixels * 3);
    final alpha = Uint8List(pixels);
    var hasAlpha = false;
    for (var i = 0, j = 0; i < pixels; i++, j += 4) {
      rgb[i * 3] = rgba[j];
      rgb[i * 3 + 1] = rgba[j + 1];
      rgb[i * 3 + 2] = rgba[j + 2];
      final a = rgba[j + 3];
      alpha[i] = a;
      if (a != 255) hasAlpha = true;
    }
    PdfRef? smask;
    if (hasAlpha) {
      smask = writer.add(
        PdfStream(
          PdfDict({
            'Type': const PdfName('XObject'),
            'Subtype': const PdfName('Image'),
            'Width': PdfNum(width),
            'Height': PdfNum(height),
            'ColorSpace': const PdfName('DeviceGray'),
            'BitsPerComponent': const PdfNum(8),
          }),
          alpha,
        ),
      );
    }
    writer.set(
      ref,
      PdfStream(
        PdfDict({
          'Type': const PdfName('XObject'),
          'Subtype': const PdfName('Image'),
          'Width': PdfNum(width),
          'Height': PdfNum(height),
          'ColorSpace': const PdfName('DeviceRGB'),
          'BitsPerComponent': const PdfNum(8),
          'SMask': ?smask,
        }),
        rgb,
      ),
    );
  }

  /// Form XObject a partir de um conteúdo já gravado. Com [transparencyGroup],
  /// o conteúdo é composto isoladamente (necessário para opacidade de grupo).
  PdfNamedRef addForm(PdfContent content, {required List<double> bbox, bool transparencyGroup = false}) {
    final dict = PdfDict({
      'Type': const PdfName('XObject'),
      'Subtype': const PdfName('Form'),
      'BBox': PdfArray.nums(bbox),
      'Resources': content.resources(),
      if (transparencyGroup) 'Group': PdfDict({'S': const PdfName('Transparency'), 'CS': const PdfName('DeviceRGB')}),
    });
    final ref = writer.add(PdfStream(dict, content.buf.toBytes()));
    return (name: 'Fm${++_formCount}', ref: ref);
  }

  PdfNamedRef addShading(PdfDict shading) => (name: 'Sh${++_shadingCount}', ref: writer.add(shading));

  PdfRef addObject(PdfObject object) => writer.add(object);

  void addPage({required double width, required double height, required PdfContent content}) {
    final contentRef = writer.add(PdfStream(PdfDict(), content.buf.toBytes()));
    final page = writer.add(
      PdfDict({
        'Type': const PdfName('Page'),
        'Parent': _pagesRef,
        'MediaBox': PdfArray.nums([0, 0, width, height]),
        'Resources': content.resources(),
        'Contents': contentRef,
      }),
    );
    _pages.add(page);
  }

  int get pageCount => _pages.length;

  Uint8List finish(PdfInfo info) {
    var index = 0;
    for (final font in _fonts.values) {
      font.write(writer, index++);
    }
    writer.set(
      _pagesRef,
      PdfDict({'Type': const PdfName('Pages'), 'Kids': PdfArray(List.of(_pages)), 'Count': PdfNum(_pages.length)}),
    );
    final catalog = writer.add(PdfDict({'Type': const PdfName('Catalog'), 'Pages': _pagesRef}));
    final now = DateTime.now();
    final infoRef = writer.add(
      PdfDict({
        if (info.title != null) 'Title': PdfString.text(info.title!),
        if (info.author != null) 'Author': PdfString.text(info.author!),
        if (info.subject != null) 'Subject': PdfString.text(info.subject!),
        if (info.keywords != null) 'Keywords': PdfString.text(info.keywords!),
        'Creator': PdfString.text(info.creator ?? 'lib_pdf'),
        'Producer': PdfString.text('lib_pdf'),
        'CreationDate': PdfString.date(now),
        'ModDate': PdfString.date(now),
      }),
    );
    return writer.finish(root: catalog, info: infoRef);
  }
}
