import 'dart:typed_data';

/// Contorno de um glifo em unidades da fonte (y para cima).
class GlyphOutline {
  /// Comandos: 0 = moveTo(x,y), 1 = lineTo(x,y), 2 = curveTo(6), 3 = close.
  final List<int> commands = [];
  final List<double> coords = [];

  bool get isEmpty => commands.isEmpty;

  void moveTo(double x, double y) {
    commands.add(0);
    coords
      ..add(x)
      ..add(y);
  }

  void lineTo(double x, double y) {
    commands.add(1);
    coords
      ..add(x)
      ..add(y);
  }

  void curveTo(double x1, double y1, double x2, double y2, double x3, double y3) {
    commands.add(2);
    coords.addAll([x1, y1, x2, y2, x3, y3]);
  }

  void close() => commands.add(3);
}

/// Leitor de contornos de fontes OpenType com tabela `CFF ` (charstrings
/// Type 2), usado para desenhar ícones e textos dessas fontes como vetores.
class CffOutlines {
  CffOutlines(Uint8List bytes, int offset, int length)
      : _data = ByteData.sublistView(bytes, offset, offset + length),
        _bytes = Uint8List.sublistView(bytes, offset, offset + length) {
    _parse();
  }

  final ByteData _data;
  final Uint8List _bytes;
  final Map<int, GlyphOutline> _cache = {};

  late final List<(int, int)> _charStrings;
  late final List<(int, int)> _globalSubrs;
  List<(int, int)> _localSubrs = const [];

  // Fontes CID: sub-rotinas locais por FD.
  List<List<(int, int)>>? _fdLocalSubrs;
  Uint8List? _fdSelect;

  GlyphOutline glyph(int gid) => _cache.putIfAbsent(gid, () => _interpret(gid));

  // ---------------------------------------------------------------------------

  int get _length => _bytes.length;

  /// Lê um INDEX: retorna a lista de (início, fim) e a posição seguinte.
  (List<(int, int)>, int) _index(int p) {
    final count = _data.getUint16(p);
    if (count == 0) return (const [], p + 2);
    final offSize = _bytes[p + 2];
    int readOffset(int i) {
      var v = 0;
      final base = p + 3 + i * offSize;
      for (var k = 0; k < offSize; k++) {
        v = (v << 8) | _bytes[base + k];
      }
      return v;
    }

    final dataStart = p + 3 + (count + 1) * offSize - 1;
    final items = <(int, int)>[
      for (var i = 0; i < count; i++) (dataStart + readOffset(i), dataStart + readOffset(i + 1)),
    ];
    return (items, dataStart + readOffset(count));
  }

  Map<int, List<double>> _dict(int start, int end) {
    final result = <int, List<double>>{};
    var operands = <double>[];
    var i = start;
    while (i < end) {
      final b = _bytes[i];
      if (b <= 21) {
        var op = b;
        i++;
        if (b == 12) {
          op = 1200 + _bytes[i];
          i++;
        }
        result[op] = operands;
        operands = [];
      } else if (b == 28) {
        operands.add(_data.getInt16(i + 1).toDouble());
        i += 3;
      } else if (b == 29) {
        operands.add(_data.getInt32(i + 1).toDouble());
        i += 5;
      } else if (b == 30) {
        // Número real em BCD: não usamos o valor, só avançamos.
        i++;
        while (i < end) {
          final nibbles = _bytes[i++];
          if ((nibbles >> 4) == 0xF || (nibbles & 0xF) == 0xF) break;
        }
        operands.add(0);
      } else if (b >= 32 && b <= 246) {
        operands.add((b - 139).toDouble());
        i++;
      } else if (b >= 247 && b <= 250) {
        operands.add(((b - 247) * 256 + _bytes[i + 1] + 108).toDouble());
        i += 2;
      } else if (b >= 251 && b <= 254) {
        operands.add((-(b - 251) * 256 - _bytes[i + 1] - 108).toDouble());
        i += 2;
      } else {
        i++;
      }
    }
    return result;
  }

  List<(int, int)> _subrsFromPrivate(Map<int, List<double>> top, int privateOp) {
    final private = top[privateOp];
    if (private == null || private.length < 2) return const [];
    final size = private[0].toInt();
    final offset = private[1].toInt();
    if (size == 0) return const [];
    final dict = _dict(offset, offset + size);
    final subrs = dict[19];
    if (subrs == null) return const [];
    return _index(offset + subrs[0].toInt()).$1;
  }

  void _parse() {
    final headerSize = _bytes[2];
    final (_, afterNames) = _index(headerSize);
    final (tops, afterTops) = _index(afterNames);
    final (_, afterStrings) = _index(afterTops);
    final (globals, _) = _index(afterStrings);
    _globalSubrs = globals;

    final top = _dict(tops.first.$1, tops.first.$2);
    _charStrings = _index(top[17]![0].toInt()).$1;
    _localSubrs = _subrsFromPrivate(top, 18);

    final fdArray = top[1236];
    final fdSelect = top[1237];
    if (fdArray != null && fdSelect != null) {
      final (fds, _) = _index(fdArray[0].toInt());
      _fdLocalSubrs = [
        for (final fd in fds) _subrsFromPrivate(_dict(fd.$1, fd.$2), 18),
      ];
      _fdSelect = _readFdSelect(fdSelect[0].toInt());
    }
  }

  Uint8List _readFdSelect(int p) {
    final count = _charStrings.length;
    final result = Uint8List(count);
    final format = _bytes[p];
    if (format == 0) {
      result.setRange(0, count, _bytes, p + 1);
    } else if (format == 3) {
      final ranges = _data.getUint16(p + 1);
      for (var r = 0; r < ranges; r++) {
        final first = _data.getUint16(p + 3 + r * 3);
        final fd = _bytes[p + 5 + r * 3];
        final next = _data.getUint16(p + 3 + (r + 1) * 3);
        for (var g = first; g < next && g < count; g++) {
          result[g] = fd;
        }
      }
    }
    return result;
  }

  static int _bias(int count) => count < 1240 ? 107 : (count < 33900 ? 1131 : 32768);

  GlyphOutline _interpret(int gid) {
    final outline = GlyphOutline();
    if (gid < 0 || gid >= _charStrings.length || _length == 0) return outline;
    final local = _fdSelect != null ? _fdLocalSubrs![_fdSelect![gid]] : _localSubrs;

    final stack = <double>[];
    var x = 0.0;
    var y = 0.0;
    var stems = 0;
    var haveWidth = false;
    var open = false;
    var depth = 0;

    void closeIfOpen() {
      if (open) outline.close();
      open = false;
    }

    void moveTo(double nx, double ny) {
      closeIfOpen();
      x = nx;
      y = ny;
      outline.moveTo(x, y);
      open = true;
    }

    void lineTo(double nx, double ny) {
      x = nx;
      y = ny;
      outline.lineTo(x, y);
    }

    void curveTo(double x1, double y1, double x2, double y2, double x3, double y3) {
      x = x3;
      y = y3;
      outline.curveTo(x1, y1, x2, y2, x3, y3);
    }

    void takeWidth(bool odd) {
      if (!haveWidth && odd && stack.isNotEmpty) stack.removeAt(0);
      haveWidth = true;
    }

    late void Function(int start, int end) run;
    var done = false;
    run = (int start, int end) {
      var i = start;
      while (i < end && !done) {
        final b = _bytes[i];
        if (b >= 32 || b == 28) {
          if (b == 28) {
            stack.add(_data.getInt16(i + 1).toDouble());
            i += 3;
          } else if (b <= 246) {
            stack.add((b - 139).toDouble());
            i++;
          } else if (b <= 250) {
            stack.add(((b - 247) * 256 + _bytes[i + 1] + 108).toDouble());
            i += 2;
          } else if (b <= 254) {
            stack.add((-(b - 251) * 256 - _bytes[i + 1] - 108).toDouble());
            i += 2;
          } else {
            stack.add(_data.getInt32(i + 1) / 65536);
            i += 5;
          }
          continue;
        }
        i++;
        switch (b) {
          case 1 || 3 || 18 || 23: // hstem, vstem, hstemhm, vstemhm
            takeWidth(stack.length.isOdd);
            stems += stack.length ~/ 2;
            stack.clear();
          case 19 || 20: // hintmask, cntrmask
            takeWidth(stack.length.isOdd);
            stems += stack.length ~/ 2;
            stack.clear();
            i += (stems + 7) >> 3;
          case 21: // rmoveto
            takeWidth(stack.length > 2);
            moveTo(x + stack[0], y + stack[1]);
            stack.clear();
          case 22: // hmoveto
            takeWidth(stack.length > 1);
            moveTo(x + stack[0], y);
            stack.clear();
          case 4: // vmoveto
            takeWidth(stack.length > 1);
            moveTo(x, y + stack[0]);
            stack.clear();
          case 5: // rlineto
            for (var k = 0; k + 1 < stack.length; k += 2) {
              lineTo(x + stack[k], y + stack[k + 1]);
            }
            stack.clear();
          case 6 || 7: // hlineto, vlineto
            var horizontal = b == 6;
            for (final v in stack) {
              if (horizontal) {
                lineTo(x + v, y);
              } else {
                lineTo(x, y + v);
              }
              horizontal = !horizontal;
            }
            stack.clear();
          case 8: // rrcurveto
            for (var k = 0; k + 5 < stack.length; k += 6) {
              curveTo(
                x + stack[k], y + stack[k + 1], //
                x + stack[k] + stack[k + 2], y + stack[k + 1] + stack[k + 3],
                x + stack[k] + stack[k + 2] + stack[k + 4], y + stack[k + 1] + stack[k + 3] + stack[k + 5],
              );
            }
            stack.clear();
          case 24: // rcurveline
            var k = 0;
            for (; k + 5 < stack.length - 2; k += 6) {
              curveTo(
                x + stack[k], y + stack[k + 1], //
                x + stack[k] + stack[k + 2], y + stack[k + 1] + stack[k + 3],
                x + stack[k] + stack[k + 2] + stack[k + 4], y + stack[k + 1] + stack[k + 3] + stack[k + 5],
              );
            }
            lineTo(x + stack[k], y + stack[k + 1]);
            stack.clear();
          case 25: // rlinecurve
            var k = 0;
            for (; k + 1 < stack.length - 6; k += 2) {
              lineTo(x + stack[k], y + stack[k + 1]);
            }
            curveTo(
              x + stack[k], y + stack[k + 1], //
              x + stack[k] + stack[k + 2], y + stack[k + 1] + stack[k + 3],
              x + stack[k] + stack[k + 2] + stack[k + 4], y + stack[k + 1] + stack[k + 3] + stack[k + 5],
            );
            stack.clear();
          case 26: // vvcurveto
            var k = 0;
            var dx1 = 0.0;
            if (stack.length.isOdd) {
              dx1 = stack[0];
              k = 1;
            }
            for (; k + 3 < stack.length; k += 4) {
              final ax = x + dx1, ay = y + stack[k];
              final bx = ax + stack[k + 1], by = ay + stack[k + 2];
              curveTo(ax, ay, bx, by, bx, by + stack[k + 3]);
              dx1 = 0;
            }
            stack.clear();
          case 27: // hhcurveto
            var k = 0;
            var dy1 = 0.0;
            if (stack.length.isOdd) {
              dy1 = stack[0];
              k = 1;
            }
            for (; k + 3 < stack.length; k += 4) {
              final ax = x + stack[k], ay = y + dy1;
              final bx = ax + stack[k + 1], by = ay + stack[k + 2];
              curveTo(ax, ay, bx, by, bx + stack[k + 3], by);
              dy1 = 0;
            }
            stack.clear();
          case 30 || 31: // vhcurveto, hvcurveto
            var horizontal = b == 31;
            var k = 0;
            while (k + 3 < stack.length) {
              final last = stack.length - k == 5;
              if (horizontal) {
                final ax = x + stack[k], ay = y;
                final bx = ax + stack[k + 1], by = ay + stack[k + 2];
                final cy = by + stack[k + 3];
                final cx = bx + (last ? stack[k + 4] : 0);
                curveTo(ax, ay, bx, by, cx, cy);
              } else {
                final ax = x, ay = y + stack[k];
                final bx = ax + stack[k + 1], by = ay + stack[k + 2];
                final cx = bx + stack[k + 3];
                final cy = by + (last ? stack[k + 4] : 0);
                curveTo(ax, ay, bx, by, cx, cy);
              }
              k += last ? 5 : 4;
              horizontal = !horizontal;
            }
            stack.clear();
          case 10 || 29: // callsubr, callgsubr
            final subrs = b == 10 ? local : _globalSubrs;
            final index = stack.removeLast().toInt() + _bias(subrs.length);
            if (index >= 0 && index < subrs.length && depth < 10) {
              depth++;
              run(subrs[index].$1, subrs[index].$2);
              depth--;
            }
          case 11: // return
            return;
          case 14: // endchar
            takeWidth(stack.isNotEmpty);
            closeIfOpen();
            done = true;
            return;
          case 12:
            final op = _bytes[i++];
            _flex(op, stack, x, y, curveTo);
            stack.clear();
          default:
            stack.clear();
        }
      }
    };

    final cs = _charStrings[gid];
    run(cs.$1, cs.$2);
    closeIfOpen();
    return outline;
  }

  void _flex(
    int op,
    List<double> s,
    double x,
    double y,
    void Function(double, double, double, double, double, double) curveTo,
  ) {
    switch (op) {
      case 35 when s.length >= 12: // flex
        final x1 = x + s[0], y1 = y + s[1];
        final x2 = x1 + s[2], y2 = y1 + s[3];
        final x3 = x2 + s[4], y3 = y2 + s[5];
        curveTo(x1, y1, x2, y2, x3, y3);
        final x4 = x3 + s[6], y4 = y3 + s[7];
        final x5 = x4 + s[8], y5 = y4 + s[9];
        curveTo(x4, y4, x5, y5, x5 + s[10], y5 + s[11]);
      case 34 when s.length >= 7: // hflex
        final x1 = x + s[0], y1 = y;
        final x2 = x1 + s[1], y2 = y1 + s[2];
        final x3 = x2 + s[3], y3 = y2;
        curveTo(x1, y1, x2, y2, x3, y3);
        final x4 = x3 + s[4], y4 = y2;
        final x5 = x4 + s[5], y5 = y;
        curveTo(x4, y4, x5, y5, x5 + s[6], y);
      case 36 when s.length >= 9: // hflex1
        final x1 = x + s[0], y1 = y + s[1];
        final x2 = x1 + s[2], y2 = y1 + s[3];
        final x3 = x2 + s[4], y3 = y2;
        curveTo(x1, y1, x2, y2, x3, y3);
        final x4 = x3 + s[5], y4 = y2;
        final x5 = x4 + s[6], y5 = y4 + s[7];
        curveTo(x4, y4, x5, y5, x5 + s[8], y);
      case 37 when s.length >= 11: // flex1
        final x1 = x + s[0], y1 = y + s[1];
        final x2 = x1 + s[2], y2 = y1 + s[3];
        final x3 = x2 + s[4], y3 = y2 + s[5];
        curveTo(x1, y1, x2, y2, x3, y3);
        final x4 = x3 + s[6], y4 = y3 + s[7];
        final x5 = x4 + s[8], y5 = y4 + s[9];
        final dx = (x5 - x).abs(), dy = (y5 - y).abs();
        if (dx > dy) {
          curveTo(x4, y4, x5, y5, x5 + s[10], y);
        } else {
          curveTo(x4, y4, x5, y5, x, y5 + s[10]);
        }
    }
  }
}
