import 'dart:typed_data';

import 'objects.dart';

/// Monta o arquivo PDF: objetos indiretos, tabela xref e trailer.
class PdfWriter {
  final List<PdfObject?> _objects = [];

  /// Reserva um número de objeto para ser preenchido depois com [set].
  PdfRef reserve() {
    _objects.add(null);
    return PdfRef(_objects.length);
  }

  PdfRef add(PdfObject object) {
    _objects.add(object);
    return PdfRef(_objects.length);
  }

  void set(PdfRef ref, PdfObject object) => _objects[ref.id - 1] = object;

  Uint8List finish({required PdfRef root, PdfRef? info}) {
    final out = PdfByteBuffer(1 << 16);
    out.ascii('%PDF-1.7\n');
    // Comentário com bytes altos: sinaliza conteúdo binário para transportes.
    out.bytes(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = List<int>.filled(_objects.length, 0);
    for (var i = 0; i < _objects.length; i++) {
      final object = _objects[i];
      if (object == null) {
        throw StateError('Objeto PDF ${i + 1} reservado e nunca definido');
      }
      offsets[i] = out.length;
      out.ascii('${i + 1} 0 obj\n');
      object.writeTo(out);
      out.ascii('\nendobj\n');
    }

    final xref = out.length;
    out.ascii('xref\n0 ${_objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets) {
      out.ascii('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    final trailer = PdfDict({
      'Size': PdfNum(_objects.length + 1),
      'Root': root,
      'Info': ?info,
    });
    out.ascii('trailer\n');
    trailer.writeTo(out);
    out.ascii('\nstartxref\n$xref\n%%EOF\n');
    return out.toBytes();
  }
}
