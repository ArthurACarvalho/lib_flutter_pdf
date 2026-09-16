import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'support/pdf_tools.dart';

void main() {
  testWidgets('fonte registrada com PdfFont é usada no layout e embutida no PDF', (tester) async {
    final doc = PdfDocument(
      fonts: [PdfFont.memory(File('fonts/Roboto-Light.ttf').readAsBytesSync(), family: 'MinhaFonte')],
    )..addPage(PdfPage(
        build: (ctx) => const Column(children: [
          Text('Fonte padrão'),
          Text('Fonte própria çãõ', style: TextStyle(fontFamily: 'MinhaFonte', fontSize: 18)),
          Text('Negrito sintético', style: TextStyle(fontFamily: 'MinhaFonte', fontWeight: FontWeight.bold)),
        ]),
      ));
    final bytes = (await tester.runAsync(doc.save))!;
    final path = '${PdfTools.outputDir()}/fonts.pdf';
    File(path).writeAsBytesSync(bytes);

    final fonts = String.fromCharCodes(bytes);
    expect(fonts, contains('+Roboto-Regular'));
    expect(fonts, contains('+Roboto-Light'));
    // Nenhum parágrafo precisou virar imagem.
    expect(fonts, isNot(contains('/Subtype /Image')));
    final text = PdfTools.run('pdftotext', [path, '-']);
    if (text != null) expect(text.stdout, contains('Fonte própria çãõ'));
  });
}
