import 'objects.dart';

/// Construtor de um content stream (de página ou de Form XObject), que
/// também registra os recursos nomeados que ele usa.
class PdfContent {
  final PdfByteBuffer buf = PdfByteBuffer(4096);

  final Map<String, PdfRef> fonts = {};
  final Map<String, PdfRef> xObjects = {};
  final Map<String, PdfRef> extGStates = {};
  final Map<String, PdfRef> shadings = {};

  bool get isEmpty => buf.length == 0;

  void _n(double v) {
    buf.number(v);
    buf.byte(0x20);
  }

  void _op(String op) {
    buf.ascii(op);
    buf.byte(0x0A);
  }

  void save() => _op('q');
  void restore() => _op('Q');

  void transform(double a, double b, double c, double d, double e, double f) {
    _n(a);
    _n(b);
    _n(c);
    _n(d);
    _n(e);
    _n(f);
    _op('cm');
  }

  void moveTo(double x, double y) {
    _n(x);
    _n(y);
    _op('m');
  }

  void lineTo(double x, double y) {
    _n(x);
    _n(y);
    _op('l');
  }

  void curveTo(double x1, double y1, double x2, double y2, double x3, double y3) {
    _n(x1);
    _n(y1);
    _n(x2);
    _n(y2);
    _n(x3);
    _n(y3);
    _op('c');
  }

  void closePath() => _op('h');

  void rect(double x, double y, double w, double h) {
    _n(x);
    _n(y);
    _n(w);
    _n(h);
    _op('re');
  }

  void fill({bool evenOdd = false}) => _op(evenOdd ? 'f*' : 'f');
  void stroke() => _op('S');
  void endPath() => _op('n');

  void clip({bool evenOdd = false}) {
    buf.ascii(evenOdd ? 'W* ' : 'W ');
    _op('n');
  }

  void fillRgb(double r, double g, double b) {
    _n(r);
    _n(g);
    _n(b);
    _op('rg');
  }

  void strokeRgb(double r, double g, double b) {
    _n(r);
    _n(g);
    _n(b);
    _op('RG');
  }

  void lineWidth(double w) {
    _n(w);
    _op('w');
  }

  /// 0 = butt, 1 = round, 2 = square.
  void lineCap(int cap) => _op('$cap J');

  /// 0 = miter, 1 = round, 2 = bevel.
  void lineJoin(int join) => _op('$join j');

  void miterLimit(double m) {
    _n(m);
    _op('M');
  }

  void extGState(String name, PdfRef ref) {
    extGStates[name] = ref;
    buf.ascii('/$name ');
    _op('gs');
  }

  void xObject(String name, PdfRef ref) {
    xObjects[name] = ref;
    buf.ascii('/$name ');
    _op('Do');
  }

  void shading(String name, PdfRef ref) {
    shadings[name] = ref;
    buf.ascii('/$name ');
    _op('sh');
  }

  // Texto -------------------------------------------------------------------

  void beginText() => _op('BT');
  void endText() => _op('ET');

  void font(String name, PdfRef ref, double size) {
    fonts[name] = ref;
    buf.ascii('/$name ');
    _n(size);
    _op('Tf');
  }

  void textMatrix(double a, double b, double c, double d, double e, double f) {
    _n(a);
    _n(b);
    _n(c);
    _n(d);
    _n(e);
    _n(f);
    _op('Tm');
  }

  void horizontalScale(double percent) {
    _n(percent);
    _op('Tz');
  }

  void charSpacing(double v) {
    _n(v);
    _op('Tc');
  }

  /// 0 = preencher, 1 = contorno, 2 = ambos, 3 = invisível.
  void textRenderMode(int mode) => _op('$mode Tr');

  /// Mostra glifos codificados em 2 bytes (Identity-H).
  void showGlyphs(List<int> glyphIds) {
    buf.byte(0x3C);
    for (final g in glyphIds) {
      _hex4(g);
    }
    buf.ascii('> ');
    _op('Tj');
  }

  /// Glifos com ajustes após cada um, em milésimos de em (positivo aproxima).
  void showGlyphsAdjusted(List<int> glyphIds, List<double> adjustments) {
    buf.ascii('[<');
    for (var i = 0; i < glyphIds.length; i++) {
      _hex4(glyphIds[i]);
      if (i < glyphIds.length - 1 && adjustments[i].abs() >= 0.5) {
        buf.byte(0x3E);
        buf.number(adjustments[i]);
        buf.byte(0x3C);
      }
    }
    buf.ascii('>] ');
    _op('TJ');
  }

  void _hex4(int v) {
    const digits = '0123456789ABCDEF';
    buf
      ..byte(digits.codeUnitAt((v >> 12) & 0xF))
      ..byte(digits.codeUnitAt((v >> 8) & 0xF))
      ..byte(digits.codeUnitAt((v >> 4) & 0xF))
      ..byte(digits.codeUnitAt(v & 0xF));
  }

  /// Anexa o conteúdo de outro stream (e seus recursos).
  void append(PdfContent other) {
    buf.bytes(other.buf.view());
    fonts.addAll(other.fonts);
    xObjects.addAll(other.xObjects);
    extGStates.addAll(other.extGStates);
    shadings.addAll(other.shadings);
  }

  PdfDict resources() {
    PdfDict named(Map<String, PdfRef> m) => PdfDict({for (final e in m.entries) e.key: e.value});
    return PdfDict({
      if (fonts.isNotEmpty) 'Font': named(fonts),
      if (xObjects.isNotEmpty) 'XObject': named(xObjects),
      if (extGStates.isNotEmpty) 'ExtGState': named(extGStates),
      if (shadings.isNotEmpty) 'Shading': named(shadings),
    });
  }
}
