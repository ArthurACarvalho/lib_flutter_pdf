import 'dart:typed_data';

import '../core/objects.dart';
import '../core/writer.dart';
import 'ttf_parser.dart';
import 'ttf_subset.dart';

/// Uma fonte TrueType usada no documento: acumula os glifos desenhados e,
/// ao final, grava a fonte subsetada como Type0/CIDFontType2 com ToUnicode.
class EmbeddedFont {
  EmbeddedFont({required this.font, required this.resourceName, required this.ref});

  final TtfFont font;
  final String resourceName;
  final PdfRef ref;

  /// GID → texto que ele representa (para cópia e busca no PDF).
  final Map<int, String> _unicode = {};

  void useGlyph(int glyph, String text) {
    _unicode.putIfAbsent(glyph, () => text);
  }

  void write(PdfWriter writer, int index) {
    final used = _unicode.keys.toSet();
    final fontFile = subsetTrueType(font, used);
    final tag = _subsetTag(index);
    final baseName = '$tag+${font.postScriptName}';
    final scale = 1000 / font.unitsPerEm;

    final fileRef = writer.add(PdfStream(PdfDict({'Length1': PdfNum(fontFile.length)}), fontFile));

    var flags = 4; // simbólica (obrigatório para CIDFonts com Identity)
    if (font.fixedPitch) flags |= 1;
    if (font.italic) flags |= 64;
    final descriptorRef = writer.add(
      PdfDict({
        'Type': const PdfName('FontDescriptor'),
        'FontName': PdfName(baseName),
        'Flags': PdfNum(flags),
        'FontBBox': PdfArray.nums([
          (font.xMin * scale).round(),
          (font.yMin * scale).round(),
          (font.xMax * scale).round(),
          (font.yMax * scale).round(),
        ]),
        'ItalicAngle': PdfNum(font.italicAngle),
        'Ascent': PdfNum((font.ascender * scale).round()),
        'Descent': PdfNum((font.descender * scale).round()),
        'CapHeight': PdfNum(((font.capHeight != 0 ? font.capHeight : font.ascender) * scale).round()),
        'StemV': PdfNum((10 + 220 * (font.weightClass - 50) / 900).round()),
        'FontFile2': fileRef,
      }),
    );

    final glyphs = used.toList()..sort();
    final widths = PdfArray();
    for (var i = 0; i < glyphs.length;) {
      final start = glyphs[i];
      final run = PdfArray();
      var g = start;
      while (i < glyphs.length && glyphs[i] == g) {
        run.add(PdfNum(font.advance1000(g).round()));
        i++;
        g++;
      }
      widths
        ..add(PdfNum(start))
        ..add(run);
    }

    final cidFontRef = writer.add(
      PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('CIDFontType2'),
        'BaseFont': PdfName(baseName),
        'CIDSystemInfo': PdfDict({
          'Registry': PdfString.text('Adobe'),
          'Ordering': PdfString.text('Identity'),
          'Supplement': const PdfNum(0),
        }),
        'FontDescriptor': descriptorRef,
        'DW': PdfNum(font.advance1000(0).round()),
        'W': widths,
        'CIDToGIDMap': const PdfName('Identity'),
      }),
    );

    final toUnicodeRef = writer.add(PdfStream(PdfDict(), _toUnicodeCMap(glyphs)));

    writer.set(
      ref,
      PdfDict({
        'Type': const PdfName('Font'),
        'Subtype': const PdfName('Type0'),
        'BaseFont': PdfName(baseName),
        'Encoding': const PdfName('Identity-H'),
        'DescendantFonts': PdfArray([cidFontRef]),
        'ToUnicode': toUnicodeRef,
      }),
    );
  }

  Uint8List _toUnicodeCMap(List<int> glyphs) {
    final sb = StringBuffer()
      ..writeln('/CIDInit /ProcSet findresource begin')
      ..writeln('12 dict begin')
      ..writeln('begincmap')
      ..writeln('/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def')
      ..writeln('/CMapName /Adobe-Identity-UCS def')
      ..writeln('/CMapType 2 def')
      ..writeln('1 begincodespacerange')
      ..writeln('<0000> <FFFF>')
      ..writeln('endcodespacerange');
    for (var i = 0; i < glyphs.length; i += 100) {
      final chunk = glyphs.sublist(i, i + 100 > glyphs.length ? glyphs.length : i + 100);
      sb.writeln('${chunk.length} beginbfchar');
      for (final g in chunk) {
        final text = _unicode[g] ?? '';
        final hex = StringBuffer();
        for (final unit in text.codeUnits) {
          hex.write(unit.toRadixString(16).padLeft(4, '0').toUpperCase());
        }
        if (hex.isEmpty) hex.write('FFFD');
        sb.writeln('<${g.toRadixString(16).padLeft(4, '0').toUpperCase()}> <$hex>');
      }
      sb.writeln('endbfchar');
    }
    sb
      ..writeln('endcmap')
      ..writeln('CMapName currentdict /CMap defineresource pop')
      ..writeln('end')
      ..writeln('end');
    return Uint8List.fromList(sb.toString().codeUnits);
  }

  static String _subsetTag(int index) {
    final chars = List.filled(6, 'A');
    var v = index;
    for (var i = 5; i >= 0; i--) {
      chars[i] = String.fromCharCode(0x41 + v % 26);
      v ~/= 26;
    }
    return chars.join();
  }
}
