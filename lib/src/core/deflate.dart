import 'dart:typed_data';

/// Compressão zlib (RFC 1950/1951) implementada em Dart puro, para funcionar
/// em todas as plataformas (inclusive Web) sem `dart:io`.
abstract final class ZLib {
  /// Comprime [data] no formato zlib (cabeçalho + deflate + Adler-32).
  static Uint8List encode(List<int> data) {
    final input = data is Uint8List ? data : Uint8List.fromList(data);
    final out = _BitWriter(input.length ~/ 2 + 64);
    out.writeByte(0x78);
    out.writeByte(0x9C);
    _Deflater(input, out).run();
    out.alignToByte();
    final adler = adler32(input);
    out.writeByte((adler >> 24) & 0xFF);
    out.writeByte((adler >> 16) & 0xFF);
    out.writeByte((adler >> 8) & 0xFF);
    out.writeByte(adler & 0xFF);
    return out.takeBytes();
  }

  /// Descomprime dados no formato zlib.
  static Uint8List decode(List<int> data) {
    final input = data is Uint8List ? data : Uint8List.fromList(data);
    if (input.length < 6) throw const FormatException('zlib: dados curtos');
    final cmf = input[0];
    final flg = input[1];
    if ((cmf & 0x0F) != 8 || ((cmf << 8) | flg) % 31 != 0) {
      throw const FormatException('zlib: cabeçalho inválido');
    }
    if (flg & 0x20 != 0) throw const FormatException('zlib: dicionário preset');
    return _Inflater(input, 2).run();
  }

  static int adler32(Uint8List data) {
    var a = 1;
    var b = 0;
    var i = 0;
    final n = data.length;
    while (i < n) {
      final end = i + 3800 < n ? i + 3800 : n;
      for (; i < end; i++) {
        a += data[i];
        b += a;
      }
      a %= 65521;
      b %= 65521;
    }
    return (b << 16) | a;
  }
}

// ---------------------------------------------------------------------------
// Tabelas do formato deflate.

const _lengthBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, //
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
];
const _lengthExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, //
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, //
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
  24577,
];
const _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, //
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
];
const _codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

final Uint8List _lengthToCode = () {
  final table = Uint8List(259);
  for (var code = 0; code < 29; code++) {
    final count = 1 << _lengthExtra[code];
    for (var i = 0; i < count; i++) {
      final len = _lengthBase[code] + i;
      if (len <= 258) table[len] = code;
    }
  }
  table[258] = 28;
  return table;
}();

int _distToCode(int dist) {
  // Busca binária sobre as bases de distância.
  var lo = 0;
  var hi = 29;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (_distBase[mid] <= dist) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

// ---------------------------------------------------------------------------
// Escrita de bits (LSB primeiro, como exige o deflate).

class _BitWriter {
  _BitWriter(int capacity) : _buf = Uint8List(capacity < 256 ? 256 : capacity);

  Uint8List _buf;
  int _len = 0;
  int _bitBuf = 0;
  int _bitCount = 0;

  void _ensure(int extra) {
    if (_len + extra <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < _len + extra) {
      cap *= 2;
    }
    final next = Uint8List(cap)..setRange(0, _len, _buf);
    _buf = next;
  }

  void writeByte(int b) {
    _ensure(1);
    _buf[_len++] = b;
  }

  void writeBits(int value, int count) {
    // Mantém o acumulador abaixo de 32 bits para funcionar também na Web.
    _bitBuf |= value << _bitCount;
    _bitCount += count;
    if (_bitCount >= 8) {
      _ensure(4);
      while (_bitCount >= 8) {
        _buf[_len++] = _bitBuf & 0xFF;
        _bitBuf >>= 8;
        _bitCount -= 8;
      }
    }
  }

  /// Escreve um código de Huffman (armazenado com bits já invertidos).
  void writeCode(int reversedCode, int length) => writeBits(reversedCode, length);

  void alignToByte() {
    _ensure(8);
    while (_bitCount > 0) {
      _buf[_len++] = _bitBuf & 0xFF;
      _bitBuf >>= 8;
      _bitCount = _bitCount > 8 ? _bitCount - 8 : 0;
    }
    _bitBuf = 0;
  }

  void writeBytes(Uint8List data, int start, int end) {
    _ensure(end - start);
    _buf.setRange(_len, _len + end - start, data, start);
    _len += end - start;
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);
}

// ---------------------------------------------------------------------------
// Compressor: LZ77 com cadeias de hash + Huffman dinâmico por bloco.

class _Deflater {
  _Deflater(this.input, this.out);

  final Uint8List input;
  final _BitWriter out;

  static const _windowSize = 32768;
  static const _windowMask = _windowSize - 1;
  static const _hashBits = 15;
  static const _hashSize = 1 << _hashBits;
  static const _minMatch = 3;
  static const _maxMatch = 258;
  static const _maxChain = 48;
  static const _niceLength = 128;
  static const _blockSymbols = 1 << 15;

  // Símbolos do bloco atual: literal (<256) ou comprimento codificado
  // como 256 + len, com a distância no array paralelo.
  final Uint16List _syms = Uint16List(_blockSymbols);
  final Uint16List _dists = Uint16List(_blockSymbols);
  int _symCount = 0;
  int _blockStart = 0;

  void run() {
    final n = input.length;
    if (n == 0) {
      _writeFixedEmptyBlock();
      return;
    }
    final head = Int32List(_hashSize)..fillRange(0, _hashSize, -1);
    final prev = Int32List(_windowSize);

    int hashAt(int i) => ((input[i] << 10) ^ (input[i + 1] << 5) ^ input[i + 2]) & (_hashSize - 1);

    var i = 0;
    while (i < n) {
      var bestLen = 0;
      var bestDist = 0;
      if (i + _minMatch <= n) {
        final h = hashAt(i);
        var candidate = head[h];
        final limit = i - _windowSize;
        var chain = _maxChain;
        final maxLen = n - i < _maxMatch ? n - i : _maxMatch;
        while (candidate > limit && candidate >= 0 && chain-- > 0) {
          if (input[candidate + bestLen] == input[i + bestLen] && input[candidate] == input[i]) {
            var len = 1;
            while (len < maxLen && input[candidate + len] == input[i + len]) {
              len++;
            }
            if (len > bestLen) {
              bestLen = len;
              bestDist = i - candidate;
              if (len >= _niceLength || len == maxLen) break;
            }
          }
          candidate = prev[candidate & _windowMask];
        }
        prev[i & _windowMask] = head[h];
        head[h] = i;
      }

      if (bestLen >= _minMatch) {
        _syms[_symCount] = 256 + bestLen;
        _dists[_symCount] = bestDist;
        _symCount++;
        // Insere as posições cobertas pelo match na tabela de hash.
        final end = i + bestLen;
        for (var j = i + 1; j < end && j + _minMatch <= n; j++) {
          final h = hashAt(j);
          prev[j & _windowMask] = head[h];
          head[h] = j;
        }
        i = end;
      } else {
        _syms[_symCount] = input[i];
        _dists[_symCount] = 0;
        _symCount++;
        i++;
      }

      if (_symCount == _blockSymbols) _flushBlock(i, last: i >= n);
    }
    if (_symCount > 0 || _blockStart < n) {
      _flushBlock(n, last: true);
    } else {
      _writeFixedEmptyBlock();
    }
  }

  void _writeFixedEmptyBlock() {
    out.writeBits(1, 1); // BFINAL
    out.writeBits(1, 2); // BTYPE = fixo
    out.writeCode(0, 7); // fim de bloco (código 256 = 0000000)
  }

  void _flushBlock(int end, {required bool last}) {
    final litFreq = Int32List(286);
    final distFreq = Int32List(30);
    for (var k = 0; k < _symCount; k++) {
      final s = _syms[k];
      if (s < 256) {
        litFreq[s]++;
      } else {
        litFreq[257 + _lengthToCode[s - 256]]++;
        distFreq[_distToCode(_dists[k])]++;
      }
    }
    litFreq[256] = 1;

    final litLens = _huffmanLengths(litFreq, 15);
    final distLens = _huffmanLengths(distFreq, 15);
    // O deflate exige ao menos um código de distância.
    if (distLens.every((l) => l == 0)) distLens[0] = 1;

    var numLit = 286;
    while (numLit > 257 && litLens[numLit - 1] == 0) {
      numLit--;
    }
    var numDist = 30;
    while (numDist > 1 && distLens[numDist - 1] == 0) {
      numDist--;
    }

    // Codifica os comprimentos com RLE (símbolos 16/17/18).
    final all = Uint8List(numLit + numDist)
      ..setRange(0, numLit, litLens)
      ..setRange(numLit, numLit + numDist, distLens);
    final rleSyms = <int>[];
    final rleExtra = <int>[];
    for (var k = 0; k < all.length;) {
      final v = all[k];
      var run = 1;
      while (k + run < all.length && all[k + run] == v) {
        run++;
      }
      if (v == 0 && run >= 3) {
        final r = run > 138 ? 138 : run;
        if (r <= 10) {
          rleSyms.add(17);
          rleExtra.add(r - 3);
        } else {
          rleSyms.add(18);
          rleExtra.add(r - 11);
        }
        k += r;
      } else if (v != 0 && run >= 4) {
        rleSyms.add(v);
        rleExtra.add(0);
        var r = run - 1;
        if (r > 6) r = 6;
        rleSyms.add(16);
        rleExtra.add(r - 3);
        k += r + 1;
      } else {
        rleSyms.add(v);
        rleExtra.add(0);
        k++;
      }
    }
    final clFreq = Int32List(19);
    for (final s in rleSyms) {
      clFreq[s]++;
    }
    final clLens = _huffmanLengths(clFreq, 7);
    var numCl = 19;
    while (numCl > 4 && clLens[_codeLengthOrder[numCl - 1]] == 0) {
      numCl--;
    }

    final litCodes = _canonicalCodes(litLens);
    final distCodes = _canonicalCodes(distLens);
    final clCodes = _canonicalCodes(clLens);

    // Estima o tamanho para escolher entre bloco dinâmico e armazenado.
    var dynamicBits = 17 + numCl * 3;
    for (var k = 0; k < rleSyms.length; k++) {
      final s = rleSyms[k];
      dynamicBits +=
          clLens[s] +
          (s == 16
              ? 2
              : s == 17
              ? 3
              : s == 18
              ? 7
              : 0);
    }
    for (var k = 0; k < 286; k++) {
      if (litFreq[k] == 0) continue;
      dynamicBits += litFreq[k] * litLens[k];
      if (k >= 257) dynamicBits += litFreq[k] * _lengthExtra[k - 257];
    }
    for (var k = 0; k < 30; k++) {
      dynamicBits += distFreq[k] * (distLens[k] + _distExtra[k]);
    }
    final rawLen = end - _blockStart;
    final storedBits = 3 + 8 + 32 + rawLen * 8;

    if (storedBits <= dynamicBits && rawLen <= 0xFFFF) {
      out.writeBits(last ? 1 : 0, 1);
      out.writeBits(0, 2);
      out.alignToByte();
      out.writeByte(rawLen & 0xFF);
      out.writeByte(rawLen >> 8);
      out.writeByte(~rawLen & 0xFF);
      out.writeByte((~rawLen >> 8) & 0xFF);
      out.writeBytes(input, _blockStart, end);
    } else {
      out.writeBits(last ? 1 : 0, 1);
      out.writeBits(2, 2);
      out.writeBits(numLit - 257, 5);
      out.writeBits(numDist - 1, 5);
      out.writeBits(numCl - 4, 4);
      for (var k = 0; k < numCl; k++) {
        out.writeBits(clLens[_codeLengthOrder[k]], 3);
      }
      for (var k = 0; k < rleSyms.length; k++) {
        final s = rleSyms[k];
        out.writeCode(clCodes[s], clLens[s]);
        if (s == 16) out.writeBits(rleExtra[k], 2);
        if (s == 17) out.writeBits(rleExtra[k], 3);
        if (s == 18) out.writeBits(rleExtra[k], 7);
      }
      for (var k = 0; k < _symCount; k++) {
        final s = _syms[k];
        if (s < 256) {
          out.writeCode(litCodes[s], litLens[s]);
        } else {
          final len = s - 256;
          final lc = _lengthToCode[len];
          out.writeCode(litCodes[257 + lc], litLens[257 + lc]);
          final le = _lengthExtra[lc];
          if (le > 0) out.writeBits(len - _lengthBase[lc], le);
          final dist = _dists[k];
          final dc = _distToCode(dist);
          out.writeCode(distCodes[dc], distLens[dc]);
          final de = _distExtra[dc];
          if (de > 0) out.writeBits(dist - _distBase[dc], de);
        }
      }
      out.writeCode(litCodes[256], litLens[256]);
    }

    _symCount = 0;
    _blockStart = end;
  }
}

/// Comprimentos de código de Huffman limitados a [maxBits], calculados com o
/// algoritmo package-merge (ótimo para o limite dado).
Uint8List _huffmanLengths(Int32List freq, int maxBits) {
  final n = freq.length;
  final lens = Uint8List(n);
  final used = <int>[];
  for (var i = 0; i < n; i++) {
    if (freq[i] > 0) used.add(i);
  }
  if (used.isEmpty) return lens;
  if (used.length == 1) {
    lens[used[0]] = 1;
    return lens;
  }
  used.sort((a, b) => freq[a] - freq[b]);

  // Cada item é (peso, lista de símbolos contidos, com repetição).
  final leaves = [
    for (final s in used) _PmItem(freq[s], [s]),
  ];
  var current = List<_PmItem>.of(leaves);
  for (var level = 1; level < maxBits; level++) {
    final packages = <_PmItem>[];
    for (var k = 0; k + 1 < current.length; k += 2) {
      packages.add(
        _PmItem(current[k].weight + current[k + 1].weight, [...current[k].symbols, ...current[k + 1].symbols]),
      );
    }
    // Mescla folhas originais com os pacotes, mantendo a ordem por peso.
    final merged = <_PmItem>[];
    var a = 0;
    var b = 0;
    while (a < leaves.length || b < packages.length) {
      if (b >= packages.length || (a < leaves.length && leaves[a].weight <= packages[b].weight)) {
        merged.add(leaves[a++]);
      } else {
        merged.add(packages[b++]);
      }
    }
    current = merged;
  }
  final take = 2 * used.length - 2;
  for (var k = 0; k < take; k++) {
    for (final s in current[k].symbols) {
      lens[s]++;
    }
  }
  return lens;
}

class _PmItem {
  _PmItem(this.weight, this.symbols);
  final int weight;
  final List<int> symbols;
}

/// Códigos canônicos com os bits invertidos (prontos para escrita LSB).
Int32List _canonicalCodes(Uint8List lens) {
  var maxLen = 0;
  for (final l in lens) {
    if (l > maxLen) maxLen = l;
  }
  final blCount = Int32List(maxLen + 1);
  for (final l in lens) {
    if (l > 0) blCount[l]++;
  }
  final nextCode = Int32List(maxLen + 2);
  var code = 0;
  for (var bits = 1; bits <= maxLen; bits++) {
    code = (code + blCount[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  final codes = Int32List(lens.length);
  for (var i = 0; i < lens.length; i++) {
    final l = lens[i];
    if (l == 0) continue;
    var c = nextCode[l]++;
    var rev = 0;
    for (var k = 0; k < l; k++) {
      rev = (rev << 1) | (c & 1);
      c >>= 1;
    }
    codes[i] = rev;
  }
  return codes;
}

// ---------------------------------------------------------------------------
// Descompressor.

class _Inflater {
  _Inflater(this.input, this.pos);

  final Uint8List input;
  int pos;
  int _bitBuf = 0;
  int _bitCount = 0;

  Uint8List _out = Uint8List(1 << 16);
  int _outLen = 0;

  int _bits(int count) {
    while (_bitCount < count) {
      if (pos >= input.length) throw const FormatException('inflate: fim inesperado');
      _bitBuf |= input[pos++] << _bitCount;
      _bitCount += 8;
    }
    final v = _bitBuf & ((1 << count) - 1);
    _bitBuf >>= count;
    _bitCount -= count;
    return v;
  }

  void _ensure(int extra) {
    if (_outLen + extra <= _out.length) return;
    var cap = _out.length * 2;
    while (cap < _outLen + extra) {
      cap *= 2;
    }
    _out = Uint8List(cap)..setRange(0, _outLen, _out);
  }

  Uint8List run() {
    var last = false;
    while (!last) {
      last = _bits(1) == 1;
      final type = _bits(2);
      switch (type) {
        case 0:
          _bitBuf = 0;
          _bitCount = 0;
          final len = input[pos] | (input[pos + 1] << 8);
          pos += 4;
          _ensure(len);
          _out.setRange(_outLen, _outLen + len, input, pos);
          _outLen += len;
          pos += len;
        case 1:
          _inflateBlock(_fixedLit, _fixedDist);
        case 2:
          final hlit = _bits(5) + 257;
          final hdist = _bits(5) + 1;
          final hclen = _bits(4) + 4;
          final clLens = Uint8List(19);
          for (var i = 0; i < hclen; i++) {
            clLens[_codeLengthOrder[i]] = _bits(3);
          }
          final clTable = _HuffTable(clLens);
          final lens = Uint8List(hlit + hdist);
          for (var i = 0; i < hlit + hdist;) {
            final sym = _decode(clTable);
            if (sym < 16) {
              lens[i++] = sym;
            } else if (sym == 16) {
              final prevLen = lens[i - 1];
              for (var r = _bits(2) + 3; r > 0; r--) {
                lens[i++] = prevLen;
              }
            } else if (sym == 17) {
              i += _bits(3) + 3;
            } else {
              i += _bits(7) + 11;
            }
          }
          _inflateBlock(
            _HuffTable(Uint8List.sublistView(lens, 0, hlit)),
            _HuffTable(Uint8List.sublistView(lens, hlit)),
          );
        default:
          throw const FormatException('inflate: tipo de bloco inválido');
      }
    }
    return Uint8List.sublistView(_out, 0, _outLen);
  }

  int _decode(_HuffTable t) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len <= 15; len++) {
      code |= _bits(1);
      final count = t.counts[len];
      if (code - count < first) return t.symbols[index + (code - first)];
      index += count;
      first += count;
      first <<= 1;
      code <<= 1;
    }
    throw const FormatException('inflate: código inválido');
  }

  void _inflateBlock(_HuffTable lit, _HuffTable dist) {
    while (true) {
      final sym = _decode(lit);
      if (sym < 256) {
        _ensure(1);
        _out[_outLen++] = sym;
      } else if (sym == 256) {
        return;
      } else {
        final lc = sym - 257;
        final len = _lengthBase[lc] + _bits(_lengthExtra[lc]);
        final dc = _decode(dist);
        final d = _distBase[dc] + _bits(_distExtra[dc]);
        _ensure(len);
        var from = _outLen - d;
        for (var k = 0; k < len; k++) {
          _out[_outLen++] = _out[from++];
        }
      }
    }
  }

  static final _fixedLit = _HuffTable(
    Uint8List(288)
      ..fillRange(0, 144, 8)
      ..fillRange(144, 256, 9)
      ..fillRange(256, 280, 7)
      ..fillRange(280, 288, 8),
  );
  static final _fixedDist = _HuffTable(Uint8List(30)..fillRange(0, 30, 5));
}

class _HuffTable {
  _HuffTable(Uint8List lens) : counts = Int32List(16), symbols = Int32List(lens.length) {
    for (final l in lens) {
      counts[l]++;
    }
    counts[0] = 0;
    final offs = Int32List(16);
    for (var i = 1; i < 16; i++) {
      offs[i] = offs[i - 1] + counts[i - 1];
    }
    for (var s = 0; s < lens.length; s++) {
      if (lens[s] != 0) symbols[offs[lens[s]]++] = s;
    }
  }

  final Int32List counts;
  final Int32List symbols;
}
