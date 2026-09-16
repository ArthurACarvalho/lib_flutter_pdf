import 'dart:typed_data';

import 'ttf_parser.dart';

/// Gera uma fonte TrueType contendo apenas os contornos dos glifos usados.
///
/// Os índices dos glifos são preservados (glifos não usados ficam vazios),
/// então o PDF pode continuar usando GID = CID com `CIDToGIDMap /Identity`.
Uint8List subsetTrueType(TtfFont font, Set<int> usedGlyphs) {
  final keep = <int>{0, ...usedGlyphs};
  // Inclui recursivamente os componentes de glifos compostos.
  final pending = keep.toList();
  while (pending.isNotEmpty) {
    final g = pending.removeLast();
    if (g >= font.numGlyphs) continue;
    for (final c in font.compositeComponents(g)) {
      if (keep.add(c)) pending.add(c);
    }
  }

  // glyf + loca (formato longo).
  final glyfBuilder = BytesBuilder(copy: false);
  final loca = ByteData((font.numGlyphs + 1) * 4);
  var offset = 0;
  for (var g = 0; g < font.numGlyphs; g++) {
    loca.setUint32(g * 4, offset);
    if (!keep.contains(g)) continue;
    final r = font.glyphRange(g);
    if (r.length <= 0) continue;
    glyfBuilder.add(Uint8List.sublistView(font.bytes, r.offset, r.offset + r.length));
    offset += r.length;
    // Alinha em 4 bytes (recomendado).
    final pad = (4 - r.length % 4) % 4;
    if (pad > 0) {
      glyfBuilder.add(Uint8List(pad));
      offset += pad;
    }
  }
  loca.setUint32(font.numGlyphs * 4, offset);

  Uint8List copyTable(String tag) {
    final t = font.tables[tag]!;
    return Uint8List.fromList(Uint8List.sublistView(font.bytes, t.offset, t.offset + t.length));
  }

  final head = copyTable('head');
  ByteData.sublistView(head)
    ..setUint32(8, 0) // checkSumAdjustment, recalculado abaixo
    ..setInt16(50, 1); // indexToLocFormat = longo

  final tables = <String, Uint8List>{
    'head': head,
    'hhea': copyTable('hhea'),
    'maxp': copyTable('maxp'),
    'hmtx': copyTable('hmtx'),
    'loca': loca.buffer.asUint8List(),
    'glyf': glyfBuilder.takeBytes(),
    for (final tag in ['cvt ', 'fpgm', 'prep'])
      if (font.tables.containsKey(tag)) tag: copyTable(tag),
  };

  final bytes = _assemble(tables);
  final adjust = (0xB1B0AFBA - _checksum(bytes)) & 0xFFFFFFFF;
  final headOffset = _tableOffset(bytes, 'head');
  ByteData.sublistView(bytes).setUint32(headOffset + 8, adjust);
  return bytes;
}

Uint8List _assemble(Map<String, Uint8List> tables) {
  final tags = tables.keys.toList()..sort();
  final numTables = tags.length;
  var entrySelector = 0;
  while ((1 << (entrySelector + 1)) <= numTables) {
    entrySelector++;
  }
  final searchRange = (1 << entrySelector) * 16;

  var size = 12 + 16 * numTables;
  for (final tag in tags) {
    size += (tables[tag]!.length + 3) & ~3;
  }
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, numTables)
    ..setUint16(6, searchRange)
    ..setUint16(8, entrySelector)
    ..setUint16(10, numTables * 16 - searchRange);

  var offset = 12 + 16 * numTables;
  for (var i = 0; i < numTables; i++) {
    final tag = tags[i];
    final table = tables[tag]!;
    final rec = 12 + 16 * i;
    for (var k = 0; k < 4; k++) {
      out[rec + k] = tag.codeUnitAt(k);
    }
    bd
      ..setUint32(rec + 4, _checksum(table))
      ..setUint32(rec + 8, offset)
      ..setUint32(rec + 12, table.length);
    out.setRange(offset, offset + table.length, table);
    offset += (table.length + 3) & ~3;
  }
  return out;
}

int _tableOffset(Uint8List font, String tag) {
  final bd = ByteData.sublistView(font);
  final count = bd.getUint16(4);
  for (var i = 0; i < count; i++) {
    final rec = 12 + 16 * i;
    if (String.fromCharCodes(font, rec, rec + 4) == tag) return bd.getUint32(rec + 8);
  }
  throw StateError('tabela $tag ausente');
}

int _checksum(Uint8List data) {
  var sum = 0;
  final n = data.length;
  for (var i = 0; i < n; i += 4) {
    var word = 0;
    for (var k = 0; k < 4; k++) {
      word = (word << 8) | (i + k < n ? data[i + k] : 0);
    }
    sum = (sum + word) & 0xFFFFFFFF;
  }
  return sum;
}
