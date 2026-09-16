import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'ttf_parser.dart';

/// Fonte adicional para o relatório, carregada no Flutter e no PDF com o
/// mesmo nome de família, garantindo que layout e arquivo usem as mesmas
/// métricas. Peso e estilo são lidos da própria fonte.
class PdfFont {
  /// Fonte a partir de bytes TTF/OTF.
  PdfFont.memory(Uint8List bytes, {required this.family})
      : _bytes = bytes,
        _assetKey = null,
        _bundle = null;

  /// Fonte a partir de um asset do app (ex.: `fonts/Inter-Bold.ttf`).
  PdfFont.asset(String assetKey, {required this.family, AssetBundle? bundle})
      : _bytes = null,
        _assetKey = assetKey,
        _bundle = bundle; // ignore: prefer_initializing_formals

  final String family;
  final Uint8List? _bytes;
  final String? _assetKey;
  final AssetBundle? _bundle;

  Future<Uint8List> _load() async {
    if (_bytes != null) return _bytes;
    final data = await (_bundle ?? rootBundle).load(_assetKey!);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

class _FontFace {
  _FontFace(this.font) : weight = font.weightClass, italic = font.italic;

  final TtfFont font;
  final int weight;
  final bool italic;
}

/// Resolve família + peso + estilo do Flutter para a fonte que será
/// embutida no PDF, reproduzindo a escolha feita pelo motor de texto.
class FontRegistry {
  /// Família privada com a Roboto embutida no pacote, usada como padrão.
  static const defaultFamily = 'LibPdfRoboto';

  static const _robotoFiles = [
    'Roboto-Regular.ttf',
    'Roboto-Italic.ttf',
    'Roboto-Medium.ttf',
    'Roboto-MediumItalic.ttf',
    'Roboto-Bold.ttf',
    'Roboto-BoldItalic.ttf',
    'Roboto-Light.ttf',
    'Roboto-LightItalic.ttf',
  ];

  // Compartilhado entre documentos: registrar a mesma fonte no motor do
  // Flutter repetidas vezes só desperdiçaria memória.
  static Future<List<_FontFace>>? _defaultFaces;
  static final Map<String, Future<List<_FontFace>>> _manifestFaces = {};
  static Future<Map<String, List<String>>>? _manifest;

  final Map<String, List<_FontFace>> _families = {};

  Future<void> init({List<PdfFont> fonts = const []}) async {
    _families[defaultFamily] = await (_defaultFaces ??= _loadDefault());
    var loadedFonts = false;

    final byFamily = <String, List<PdfFont>>{};
    for (final f in fonts) {
      byFamily.putIfAbsent(f.family, () => []).add(f);
    }
    for (final entry in byFamily.entries) {
      final loader = FontLoader(entry.key);
      final faces = <_FontFace>[];
      for (final font in entry.value) {
        final bytes = await font._load();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        faces.add(_FontFace(TtfFont(bytes)));
      }
      await loader.load();
      _families[entry.key] = faces;
      loadedFonts = true;
    }
    if (loadedFonts) await _waitFontChangeNotification();
  }

  /// Registrar fontes faz o Flutter avisar os textos já montados na próxima
  /// volta do event loop. Esperar essa volta evita que as árvores do
  /// relatório (montadas logo depois) recebam o aviso e agendem frames.
  static Future<void> _waitFontChangeNotification() => Future<void>.delayed(const Duration(milliseconds: 1));

  static Future<List<_FontFace>> _loadDefault() async {
    final loader = FontLoader(defaultFamily);
    final faces = <_FontFace>[];
    for (final file in _robotoFiles) {
      final bytes = await _loadPackageAsset('fonts/$file');
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      faces.add(_FontFace(TtfFont(bytes)));
    }
    await loader.load();
    await _waitFontChangeNotification();
    return faces;
  }

  static Future<Uint8List> _loadPackageAsset(String path) async {
    ByteData data;
    try {
      data = await rootBundle.load('packages/lib_pdf/$path');
    } catch (_) {
      // Dentro dos testes do próprio pacote o asset não tem prefixo.
      data = await rootBundle.load(path);
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Garante que as famílias usadas pelo app (declaradas no pubspec) estejam
  /// disponíveis para o PDF. Famílias desconhecidas são ignoradas.
  Future<void> ensureFamilies(Iterable<String> families) async {
    final missing = families.where((f) => !_families.containsKey(f)).toSet();
    if (missing.isEmpty) return;
    final manifest = await (_manifest ??= _loadManifest());
    for (final family in missing) {
      final assets = manifest[family];
      if (assets == null) continue;
      _families[family] = await _manifestFaces.putIfAbsent(family, () async {
        final faces = <_FontFace>[];
        for (final asset in assets) {
          try {
            final data = await rootBundle.load(asset);
            faces.add(_FontFace(TtfFont(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))));
          } catch (e) {
            debugPrint('lib_pdf: não foi possível ler a fonte "$asset": $e');
          }
        }
        return faces;
      });
    }
  }

  static Future<Map<String, List<String>>> _loadManifest() async {
    try {
      final json = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
      return {
        for (final family in json.cast<Map<String, dynamic>>())
          family['family'] as String: [
            for (final font in (family['fonts'] as List<dynamic>).cast<Map<String, dynamic>>())
              font['asset'] as String,
          ],
      };
    } catch (_) {
      return {};
    }
  }

  bool knows(String family) => _families[family]?.isNotEmpty ?? false;

  /// Escolhe a face mais próxima pelas regras de correspondência do CSS,
  /// as mesmas usadas pelo motor de texto do Flutter.
  TtfFont? resolve(String? family, FontWeight? weight, FontStyle? style) {
    final faces = _families[family ?? defaultFamily];
    if (faces == null || faces.isEmpty) return null;
    final wantItalic = style == FontStyle.italic;
    var candidates = faces.where((f) => f.italic == wantItalic).toList();
    if (candidates.isEmpty) candidates = faces;

    final w = weight?.value ?? 400;
    int rank(_FontFace f) {
      final fw = f.weight;
      if (fw == w) return 0;
      if (w >= 400 && w <= 500) {
        if (fw > w && fw <= 500) return fw - w;
        if (fw < w) return 1000 + (w - fw);
        return 2000 + (fw - w);
      }
      if (w < 400) {
        if (fw < w) return w - fw;
        return 1000 + (fw - w);
      }
      if (fw > w) return fw - w;
      return 1000 + (w - fw);
    }

    candidates.sort((a, b) => rank(a) - rank(b));
    return candidates.first.font;
  }
}
