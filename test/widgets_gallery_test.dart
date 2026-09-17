import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/lib_pdf.dart';

import 'support/pdf_tools.dart';

Future<Uint8List> _logoPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawCircle(const Offset(32, 32), 30, Paint()..color = const Color(0xFF1F3A5F));
  canvas.drawRect(const Rect.fromLTWH(20, 20, 24, 24), Paint()..color = const Color(0xFFFFC107));
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('galeria de widgets: gradientes, imagens, ícones, efeitos', (tester) async {
    late Uint8List logo;
    await tester.runAsync(() async {
      logo = await _logoPng();
      final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });

    final doc = PdfDocument(title: 'Galeria');
    doc.addPage(
      PdfMultiPage(
        header: (ctx) => Row(
          children: [
            Image.memory(logo, width: 24, height: 24),
            const SizedBox(width: 8),
            const Text('Galeria de widgets'),
          ],
        ),
        build: (ctx) => [
          Container(
            height: 60,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1F3A5F), Color(0xFF4FC3F7), Color(0xFFFFFFFF)],
                stops: [0, 0.6, 1],
              ),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            alignment: Alignment.center,
            child: const Text('Gradiente linear', style: TextStyle(color: Colors.white, fontSize: 20)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Colors.yellow, Colors.deepOrange]),
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.home, size: 40, color: Colors.teal),
              const Icon(Icons.bar_chart, size: 40),
              const Icon(Icons.check_circle, size: 40, color: Colors.green),
              const SizedBox(width: 12),
              ClipOval(child: Image.memory(logo, width: 60, height: 60, fit: BoxFit.cover)),
              const SizedBox(width: 12),
              Opacity(opacity: 0.4, child: Container(width: 50, height: 50, color: Colors.purple)),
              Transform.rotate(angle: 0.3, child: Container(width: 40, height: 40, color: Colors.orange)),
            ],
          ),
          const SizedBox(height: 8),
          const Wrap(
            spacing: 8,
            children: [
              Chip(label: Text('Chip A')),
              Chip(avatar: Icon(Icons.star, size: 16), label: Text('Com ícone')),
              CircleAvatar(child: Text('AC')),
            ],
          ),
          const Divider(),
          const LinearProgressIndicator(value: 0.7),
          const SizedBox(height: 8),
          Row(
            children: const [
              Checkbox(value: true, onChanged: null),
              Text('Aprovado'),
              Switch(value: true, onChanged: null),
              Text('Ativo'),
            ],
          ),
          DataTable(
            columns: const [
              DataColumn(label: Text('Produto')),
              DataColumn(label: Text('Qtd'), numeric: true),
            ],
            rows: const [
              DataRow(cells: [DataCell(Text('Parafuso')), DataCell(Text('120'))]),
              DataRow(cells: [DataCell(Text('Porca')), DataCell(Text('80'))]),
            ],
          ),
          const Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Rich '),
                TextSpan(
                  text: 'negrito ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: 'itálico ',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                TextSpan(
                  text: 'sublinhado',
                  style: TextStyle(decoration: TextDecoration.underline, color: Colors.blue),
                ),
                WidgetSpan(child: Icon(Icons.favorite, size: 14, color: Colors.red)),
              ],
            ),
          ),
          ShaderMask(
            shaderCallback: (rect) => const LinearGradient(colors: [Colors.red, Colors.blue]).createShader(rect),
            child: const Text('ShaderMask vira imagem', style: TextStyle(fontSize: 18, color: Colors.white)),
          ),
        ],
      ),
    );

    final bytes = (await tester.runAsync(doc.save))!;
    final path = '${PdfTools.outputDir()}/gallery.pdf';
    File(path).writeAsBytesSync(bytes);
    final check = PdfTools.run('qpdf', ['--check', path]);
    if (check != null) expect(check.exitCode, 0, reason: '${check.stdout}${check.stderr}');
    final images = PdfTools.run('pdfimages', ['-list', path]);
    if (images != null) debugPrint(images.stdout as String);
    final text = PdfTools.run('pdftotext', [path, '-']);
    if (text != null) {
      expect(text.stdout, contains('Gradiente linear'));
      expect(text.stdout, contains('Parafuso'));
    }
  });
}
