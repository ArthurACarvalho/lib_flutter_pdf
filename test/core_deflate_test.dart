import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lib_pdf/src/core/deflate.dart';

void main() {
  Uint8List roundTrip(List<int> data) => ZLib.decode(ZLib.encode(data));

  test('dados vazios e pequenos', () {
    expect(roundTrip([]), isEmpty);
    expect(roundTrip([65]), [65]);
    expect(roundTrip('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.codeUnits), 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'.codeUnits);
  });

  test('texto repetitivo comprime e volta igual', () {
    final text = List.generate(5000, (i) => 'linha $i do relatório: 0 0 m 10 10 l S\n').join();
    final data = Uint8List.fromList(text.codeUnits.map((c) => c & 0xFF).toList());
    final packed = ZLib.encode(data);
    expect(packed.length, lessThan(data.length ~/ 5));
    expect(ZLib.decode(packed), data);
  });

  test('dados aleatórios grandes (blocos armazenados)', () {
    final rnd = Random(42);
    final data = Uint8List.fromList(List.generate(300000, (_) => rnd.nextInt(256)));
    expect(roundTrip(data), data);
  });

  test('dados mistos com poucos símbolos', () {
    final rnd = Random(7);
    final data = Uint8List.fromList(List.generate(200000, (i) => rnd.nextInt(4) + (i ~/ 5000)));
    expect(roundTrip(data), data);
  });

  test('compatível com o zlib do sistema', () {
    final rnd = Random(3);
    final data = Uint8List.fromList(List.generate(120000, (i) => (i % 97 < 40) ? rnd.nextInt(256) : i % 13));
    expect(zlib.decode(ZLib.encode(data)), data);
    expect(ZLib.decode(zlib.encode(data)), data);
  });
}
