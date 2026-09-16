import 'dart:io';

/// Ferramentas externas (qpdf/poppler) opcionais para validar os PDFs.
/// Configure com LIB_PDF_TOOLS apontando para um script que exporta PATH e
/// LD_LIBRARY_PATH, ou tenha as ferramentas instaladas no sistema.
class PdfTools {
  static Map<String, String> get _env {
    final script = Platform.environment['LIB_PDF_TOOLS'];
    if (script == null) return {};
    final result = Process.runSync('bash', ['-c', 'source $script && env']);
    return {
      for (final line in (result.stdout as String).split('\n'))
        if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
    };
  }

  static ProcessResult? run(String tool, List<String> args) {
    try {
      return Process.runSync(tool, args, environment: _env);
    } on ProcessException {
      return null;
    }
  }

  static String outputDir() {
    final dir = Directory('build/test_output')..createSync(recursive: true);
    return dir.path;
  }
}
