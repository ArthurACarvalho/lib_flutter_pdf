import 'dart:convert';
import 'dart:typed_data';

import 'deflate.dart';

/// Buffer de bytes com crescimento amortizado, usado em toda a serialização.
class PdfByteBuffer {
  PdfByteBuffer([int capacity = 1024]) : _buf = Uint8List(capacity);

  Uint8List _buf;
  int _len = 0;

  int get length => _len;

  /// Descarta tudo que foi escrito depois de [length] bytes.
  void truncate(int length) {
    assert(length <= _len);
    _len = length;
  }

  void _ensure(int extra) {
    if (_len + extra <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < _len + extra) {
      cap *= 2;
    }
    _buf = Uint8List(cap)..setRange(0, _len, _buf);
  }

  void byte(int b) {
    _ensure(1);
    _buf[_len++] = b;
  }

  void bytes(List<int> data) {
    _ensure(data.length);
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;
  }

  /// Escreve texto ASCII (operadores, nomes, números).
  void ascii(String s) {
    _ensure(s.length);
    for (var i = 0; i < s.length; i++) {
      _buf[_len++] = s.codeUnitAt(i) & 0xFF;
    }
  }

  void number(double v) => ascii(formatPdfNumber(v));

  Uint8List toBytes() => Uint8List.fromList(Uint8List.sublistView(_buf, 0, _len));

  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);
}

/// Formata números de forma compacta: inteiros sem casas, reais com até 4.
String formatPdfNumber(double v) {
  if (v.isNaN || v.isInfinite) return '0';
  final r = v.roundToDouble();
  if ((v - r).abs() < 0.00005) {
    if (r.abs() < 1e15) return r == 0 ? '0' : r.toInt().toString();
  }
  var s = v.toStringAsFixed(4);
  // Remove zeros à direita e o ponto final.
  var end = s.length;
  while (s.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  if (s.codeUnitAt(end - 1) == 0x2E) end--;
  s = s.substring(0, end);
  if (s.startsWith('0.')) return s.substring(1);
  if (s.startsWith('-0.')) return '-${s.substring(2)}';
  return s;
}

/// Qualquer valor serializável em PDF.
abstract class PdfObject {
  const PdfObject();

  void writeTo(PdfByteBuffer out);
}

class PdfNull extends PdfObject {
  const PdfNull();

  @override
  void writeTo(PdfByteBuffer out) => out.ascii('null');
}

class PdfBool extends PdfObject {
  const PdfBool(this.value);

  final bool value;

  @override
  void writeTo(PdfByteBuffer out) => out.ascii(value ? 'true' : 'false');
}

class PdfNum extends PdfObject {
  const PdfNum(this.value);

  final num value;

  @override
  void writeTo(PdfByteBuffer out) => out.number(value.toDouble());
}

class PdfName extends PdfObject {
  const PdfName(this.name);

  final String name;

  @override
  void writeTo(PdfByteBuffer out) {
    out.byte(0x2F);
    for (final b in utf8.encode(name)) {
      // Delimitadores, espaços e não-ASCII são escapados como #xx.
      if (b < 0x21 || b > 0x7E || '#()<>[]{}/%'.codeUnits.contains(b)) {
        out.ascii('#${b.toRadixString(16).padLeft(2, '0')}');
      } else {
        out.byte(b);
      }
    }
  }
}

class PdfString extends PdfObject {
  const PdfString(this.bytes, {this.hex = false});

  /// Texto legível (metadados): ASCII puro vira string literal; o resto,
  /// UTF-16BE com BOM, como manda a especificação.
  factory PdfString.text(String text) {
    final isAscii = text.codeUnits.every((c) => c < 0x80);
    if (isAscii) return PdfString(Uint8List.fromList(text.codeUnits));
    final data = <int>[0xFE, 0xFF];
    for (final c in text.codeUnits) {
      data
        ..add(c >> 8)
        ..add(c & 0xFF);
    }
    return PdfString(Uint8List.fromList(data), hex: true);
  }

  factory PdfString.date(DateTime date) {
    final u = date.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return PdfString(Uint8List.fromList(
      'D:${u.year.toString().padLeft(4, '0')}${two(u.month)}${two(u.day)}'
              '${two(u.hour)}${two(u.minute)}${two(u.second)}Z'
          .codeUnits,
    ));
  }

  final Uint8List bytes;
  final bool hex;

  @override
  void writeTo(PdfByteBuffer out) => writeStringBytes(out, bytes, hex: hex);

  static void writeStringBytes(PdfByteBuffer out, List<int> bytes, {bool hex = false}) {
    if (hex) {
      out.byte(0x3C);
      for (final b in bytes) {
        out
          ..byte(_hexDigit(b >> 4))
          ..byte(_hexDigit(b & 0xF));
      }
      out.byte(0x3E);
      return;
    }
    out.byte(0x28);
    for (final b in bytes) {
      switch (b) {
        case 0x28 || 0x29 || 0x5C:
          out
            ..byte(0x5C)
            ..byte(b);
        case 0x0A:
          out.ascii(r'\n');
        case 0x0D:
          out.ascii(r'\r');
        default:
          out.byte(b);
      }
    }
    out.byte(0x29);
  }

  static int _hexDigit(int v) => v < 10 ? 0x30 + v : 0x41 + v - 10;
}

class PdfArray extends PdfObject {
  PdfArray([List<PdfObject>? values]) : values = values ?? [];

  factory PdfArray.nums(Iterable<num> values) =>
      PdfArray([for (final v in values) PdfNum(v)]);

  final List<PdfObject> values;

  void add(PdfObject v) => values.add(v);

  @override
  void writeTo(PdfByteBuffer out) {
    out.byte(0x5B);
    for (var i = 0; i < values.length; i++) {
      if (i > 0) out.byte(0x20);
      values[i].writeTo(out);
    }
    out.byte(0x5D);
  }
}

class PdfDict extends PdfObject {
  PdfDict([Map<String, PdfObject>? values]) : values = values ?? {};

  final Map<String, PdfObject> values;

  void operator []=(String key, PdfObject value) => values[key] = value;

  PdfObject? operator [](String key) => values[key];

  @override
  void writeTo(PdfByteBuffer out) {
    out.ascii('<<');
    for (final entry in values.entries) {
      PdfName(entry.key).writeTo(out);
      out.byte(0x20);
      entry.value.writeTo(out);
    }
    out.ascii('>>');
  }
}

/// Referência a um objeto indireto (`n 0 R`).
class PdfRef extends PdfObject {
  const PdfRef(this.id);

  final int id;

  @override
  void writeTo(PdfByteBuffer out) => out.ascii('$id 0 R');

  @override
  bool operator ==(Object other) => other is PdfRef && other.id == id;

  @override
  int get hashCode => id;
}

class PdfStream extends PdfObject {
  PdfStream(this.dict, this.data, {this.compress = true});

  final PdfDict dict;
  final Uint8List data;

  /// Comprime com FlateDecode quando o resultado ficar menor.
  final bool compress;

  @override
  void writeTo(PdfByteBuffer out) {
    var payload = data;
    if (compress && data.length > 32 && dict['Filter'] == null) {
      final packed = ZLib.encode(data);
      if (packed.length < data.length) {
        payload = packed;
        dict['Filter'] = const PdfName('FlateDecode');
      }
    }
    dict['Length'] = PdfNum(payload.length);
    dict.writeTo(out);
    out.ascii('\nstream\n');
    out.bytes(payload);
    out.ascii('\nendstream');
  }
}
