import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/src/core/content.dart';
import 'package:lib_pdf/src/core/document_builder.dart';
import 'package:lib_pdf/src/core/objects.dart';
import 'package:lib_pdf/src/font/ttf_parser.dart';

void main() {
  test('números compactos', () {
    expect(formatPdfNumber(1), '1');
    expect(formatPdfNumber(-0.0), '0');
    expect(formatPdfNumber(0.5), '.5');
    expect(formatPdfNumber(-0.25), '-.25');
    expect(formatPdfNumber(12.30004), '12.3');
    expect(formatPdfNumber(595.2756), '595.2756');
  });

  test('escape de strings literais', () {
    final out = PdfByteBuffer();
    PdfString(Uint8List.fromList('a(b)c\\'.codeUnits)).writeTo(out);
    expect(String.fromCharCodes(out.view()), r'(a\(b\)c\\)');
  });

  test('gera PDF com retângulos e texto Roboto', () {
    final font = TtfFont(File('fonts/Roboto-Regular.ttf').readAsBytesSync());
    expect(font.unitsPerEm, 2048);
    expect(font.hasGlyph('ç'.codeUnitAt(0)), isTrue);

    final doc = PdfDocumentBuilder();
    final content = PdfContent()
      ..transform(1, 0, 0, -1, 0, 842)
      ..fillRgb(0.12, 0.23, 0.37)
      ..rect(40, 40, 200, 100)
      ..fill();
    final embedded = doc.font(font);
    const text = 'Olá, acentuação ção!';
    final glyphs = <int>[];
    for (final rune in text.runes) {
      final g = font.glyphForCodePoint(rune);
      embedded.useGlyph(g, String.fromCharCode(rune));
      glyphs.add(g);
    }
    content
      ..fillRgb(0, 0, 0)
      ..beginText()
      ..font(embedded.resourceName, embedded.ref, 24)
      ..textMatrix(1, 0, 0, -1, 40, 200)
      ..showGlyphs(glyphs)
      ..endText();
    doc.addPage(width: 595, height: 842, content: content);
    final bytes = doc.finish(const PdfInfo(title: 'Teste çã'));

    // Confere os offsets da xref relendo o arquivo.
    final s = String.fromCharCodes(bytes);
    final startxref = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(s)!.group(1)!);
    expect(s.substring(startxref, startxref + 4), 'xref');
    final entries = RegExp(r'(\d{10}) 00000 n ').allMatches(s.substring(startxref)).toList();
    for (var i = 0; i < entries.length; i++) {
      final offset = int.parse(entries[i].group(1)!);
      expect(s.substring(offset).startsWith('${i + 1} 0 obj'), isTrue, reason: 'objeto ${i + 1}');
    }

    Directory('build/test_output').createSync(recursive: true);
    File('build/test_output/core.pdf').writeAsBytesSync(bytes);
  });
}
