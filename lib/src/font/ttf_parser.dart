import 'dart:typed_data';

import 'cff_outlines.dart';

/// Leitura das tabelas de uma fonte TrueType/OpenType necessárias para
/// medir, subsetar e embutir a fonte no PDF.
class TtfFont {
  TtfFont(Uint8List bytes) : data = ByteData.sublistView(bytes), bytes = bytes {
    _parseDirectory();
    _parseHead();
    _parseHhea();
    _parseMaxp();
    _parseHmtx();
    _parseCmap();
    _parseOs2();
    _parsePost();
    _parseName();
  }

  final Uint8List bytes;
  final ByteData data;

  /// Posição e tamanho de cada tabela, pela tag de 4 letras.
  final Map<String, ({int offset, int length})> tables = {};

  late final bool isCff;
  late final int unitsPerEm;
  late final int indexToLocFormat;
  late final int xMin, yMin, xMax, yMax;
  late final int macStyle;
  late final int ascender, descender, lineGap;
  late final int numberOfHMetrics;
  late final int numGlyphs;
  late final Uint16List advanceWidths;
  final Map<int, int> _cmap = {};
  int weightClass = 400;
  bool italic = false;
  int capHeight = 0;
  double italicAngle = 0;
  bool fixedPitch = false;
  int underlinePosition = 0;
  int underlineThickness = 0;
  int strikeoutPosition = 0;
  int strikeoutSize = 0;
  String familyName = '';
  String postScriptName = 'Font';

  /// Contornos das fontes OpenType/CFF (desenhadas como caminhos no PDF).
  late final CffOutlines? cffOutlines = isCff && tables.containsKey('CFF ')
      ? CffOutlines(bytes, tables['CFF ']!.offset, tables['CFF ']!.length)
      : null;

  int glyphForCodePoint(int codePoint) => _cmap[codePoint] ?? 0;

  bool hasGlyph(int codePoint) => (_cmap[codePoint] ?? 0) != 0;

  Map<int, int> get cmap => _cmap;

  /// Avanço horizontal em unidades de 1/1000 em.
  double advance1000(int glyph) {
    final w = glyph < advanceWidths.length ? advanceWidths[glyph] : advanceWidths.last;
    return w * 1000 / unitsPerEm;
  }

  int _u16(int o) => data.getUint16(o);
  int _i16(int o) => data.getInt16(o);
  int _u32(int o) => data.getUint32(o);

  void _parseDirectory() {
    final version = _u32(0);
    if (version == 0x74746366) {
      throw const FormatException('Coleções TTC não são suportadas; use um .ttf/.otf');
    }
    isCff = version == 0x4F54544F; // 'OTTO'
    final count = _u16(4);
    for (var i = 0; i < count; i++) {
      final rec = 12 + 16 * i;
      final tag = String.fromCharCodes(bytes, rec, rec + 4);
      tables[tag] = (offset: _u32(rec + 8), length: _u32(rec + 12));
    }
    for (final required in ['head', 'hhea', 'maxp', 'hmtx']) {
      if (!tables.containsKey(required)) {
        throw FormatException('Fonte sem a tabela obrigatória "$required"');
      }
    }
  }

  void _parseHead() {
    final o = tables['head']!.offset;
    unitsPerEm = _u16(o + 18);
    xMin = _i16(o + 36);
    yMin = _i16(o + 38);
    xMax = _i16(o + 40);
    yMax = _i16(o + 42);
    macStyle = _u16(o + 44);
    indexToLocFormat = _i16(o + 50);
  }

  void _parseHhea() {
    final o = tables['hhea']!.offset;
    ascender = _i16(o + 4);
    descender = _i16(o + 6);
    lineGap = _i16(o + 8);
    numberOfHMetrics = _u16(o + 34);
  }

  void _parseMaxp() {
    numGlyphs = _u16(tables['maxp']!.offset + 4);
  }

  void _parseHmtx() {
    final o = tables['hmtx']!.offset;
    advanceWidths = Uint16List(numGlyphs);
    var last = 0;
    for (var i = 0; i < numGlyphs; i++) {
      if (i < numberOfHMetrics) last = _u16(o + i * 4);
      advanceWidths[i] = last;
    }
  }

  void _parseCmap() {
    final table = tables['cmap'];
    if (table == null) return;
    final o = table.offset;
    final count = _u16(o + 2);
    int? best;
    var bestScore = -1;
    for (var i = 0; i < count; i++) {
      final rec = o + 4 + i * 8;
      final platform = _u16(rec);
      final encoding = _u16(rec + 2);
      final sub = o + _u32(rec + 4);
      final format = _u16(sub);
      var score = -1;
      if (format == 12 && (platform == 3 && encoding == 10 || platform == 0)) score = 4;
      if (format == 4 && (platform == 3 && encoding == 1 || platform == 0)) score = 3;
      if (format == 4 && platform == 3 && encoding == 0) score = 2; // símbolos
      if (score > bestScore) {
        bestScore = score;
        best = sub;
      }
    }
    if (best == null) return;
    final format = _u16(best);
    if (format == 4) {
      final segX2 = _u16(best + 6);
      final ends = best + 14;
      final starts = ends + segX2 + 2;
      final deltas = starts + segX2;
      final rangeOffsets = deltas + segX2;
      for (var s = 0; s < segX2 ~/ 2; s++) {
        final end = _u16(ends + s * 2);
        final start = _u16(starts + s * 2);
        final delta = _u16(deltas + s * 2);
        final rangeOffset = _u16(rangeOffsets + s * 2);
        if (start == 0xFFFF) break;
        for (var c = start; c <= end; c++) {
          int glyph;
          if (rangeOffset == 0) {
            glyph = (c + delta) & 0xFFFF;
          } else {
            final addr = rangeOffsets + s * 2 + rangeOffset + (c - start) * 2;
            glyph = _u16(addr);
            if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
          }
          // Fontes de símbolos (3,0) mapeiam em U+F0xx.
          if (glyph != 0) {
            _cmap[c] = glyph;
            if (bestScore == 2 && c >= 0xF000 && c <= 0xF0FF) _cmap.putIfAbsent(c - 0xF000, () => glyph);
          }
        }
      }
    } else if (format == 12) {
      final groups = _u32(best + 12);
      for (var g = 0; g < groups; g++) {
        final rec = best + 16 + g * 12;
        final start = _u32(rec);
        final end = _u32(rec + 4);
        final glyph = _u32(rec + 8);
        for (var c = start; c <= end; c++) {
          _cmap[c] = glyph + (c - start);
        }
      }
    }
  }

  void _parseOs2() {
    final t = tables['OS/2'];
    if (t == null) {
      italic = macStyle & 2 != 0;
      weightClass = macStyle & 1 != 0 ? 700 : 400;
      return;
    }
    final o = t.offset;
    final version = _u16(o);
    weightClass = _u16(o + 4);
    strikeoutSize = _i16(o + 26);
    strikeoutPosition = _i16(o + 28);
    final fsSelection = _u16(o + 62);
    italic = fsSelection & 1 != 0 || macStyle & 2 != 0;
    if (version >= 2 && t.length >= 90) capHeight = _i16(o + 88);
  }

  void _parsePost() {
    final t = tables['post'];
    if (t == null) return;
    italicAngle = data.getInt32(t.offset + 4) / 65536;
    underlinePosition = _i16(t.offset + 8);
    underlineThickness = _i16(t.offset + 10);
    fixedPitch = _u32(t.offset + 12) != 0;
  }

  void _parseName() {
    final t = tables['name'];
    if (t == null) return;
    final o = t.offset;
    final count = _u16(o + 2);
    final storage = o + _u16(o + 4);
    String? read(int wantedId) {
      String? fallback;
      for (var i = 0; i < count; i++) {
        final rec = o + 6 + i * 12;
        final platform = _u16(rec);
        final nameId = _u16(rec + 6);
        if (nameId != wantedId) continue;
        final length = _u16(rec + 8);
        final start = storage + _u16(rec + 10);
        if (platform == 3 || platform == 0) {
          final units = <int>[];
          for (var k = 0; k + 1 < length; k += 2) {
            units.add(_u16(start + k));
          }
          return String.fromCharCodes(units);
        }
        fallback ??= String.fromCharCodes(bytes, start, start + length);
      }
      return fallback;
    }

    familyName = read(16) ?? read(1) ?? '';
    final ps = read(6);
    if (ps != null && ps.isNotEmpty) {
      postScriptName = ps.replaceAll(RegExp(r'[^A-Za-z0-9\-_]'), '');
    } else if (familyName.isNotEmpty) {
      postScriptName = familyName.replaceAll(RegExp(r'[^A-Za-z0-9\-_]'), '');
    }
  }

  // Glifos TrueType ----------------------------------------------------------

  int _locaOffset(int glyph) {
    final loca = tables['loca']!.offset;
    return indexToLocFormat == 0 ? _u16(loca + glyph * 2) * 2 : _u32(loca + glyph * 4);
  }

  /// Faixa de bytes do glifo dentro da tabela `glyf` (tamanho 0 = vazio).
  ({int offset, int length}) glyphRange(int glyph) {
    final start = _locaOffset(glyph);
    final end = _locaOffset(glyph + 1);
    return (offset: tables['glyf']!.offset + start, length: end - start);
  }

  /// Glifos referenciados por um glifo composto.
  List<int> compositeComponents(int glyph) {
    final r = glyphRange(glyph);
    if (r.length < 10 || _i16(r.offset) >= 0) return const [];
    final result = <int>[];
    var p = r.offset + 10;
    while (true) {
      final flags = _u16(p);
      result.add(_u16(p + 2));
      p += 4;
      p += flags & 0x0001 != 0 ? 4 : 2; // ARG_1_AND_2_ARE_WORDS
      if (flags & 0x0008 != 0) {
        p += 2; // WE_HAVE_A_SCALE
      } else if (flags & 0x0040 != 0) {
        p += 4; // X_AND_Y_SCALE
      } else if (flags & 0x0080 != 0) {
        p += 8; // TWO_BY_TWO
      }
      if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
    }
    return result;
  }
}
