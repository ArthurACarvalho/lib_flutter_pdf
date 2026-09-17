import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../pdf_document.dart';
import 'viewer_backend.dart';

/// Cores do visualizador (tema claro, independente do tema do app).
abstract final class _Palette {
  static const background = Color(0xFFF0F2F5);
  static const bar = Color(0xFFFFFFFF);
  static const divider = Color(0xFFE4E7EC);
  static const outline = Color(0xFFD0D5DD);
  static const hover = Color(0xFFF2F4F7);
  static const splash = Color(0x66D0D5DD);
  static const icon = Color(0xFF344054);
  static const disabled = Color(0xFFBAC1CC);
  static const text = Color(0xFF101828);
  static const muted = Color(0xFF667085);
  static const pdf = Color(0xFFE5483B);
}

/// Controla um [PdfDocumentViewer] de fora (ex.: barra de ferramentas própria).
class PdfDocumentViewerController extends ChangeNotifier {
  _PdfDocumentViewerState? _state;

  int _pageCount = 0;
  int _pageNumber = 1;
  double _zoom = 1;
  bool _fitsPage = false;
  bool _printing = false;
  bool _saving = false;
  bool _disposed = false;

  /// Se o documento já foi gerado e as páginas estão prontas.
  bool get isReady => _pageCount > 0;

  int get pageCount => _pageCount;

  /// Página em destaque na tela (começa em 1).
  int get pageNumber => _pageNumber;

  /// 1.0 = página ajustada à largura do visualizador.
  double get zoom => _zoom;

  /// Se o zoom foi ajustado para a página inteira caber na tela ([fitPage]).
  bool get fitsPage => _fitsPage;

  bool get isPrinting => _printing;

  bool get isSaving => _saving;

  /// Bytes do PDF exibido (nulo enquanto é gerado).
  Uint8List? get bytes => _state?._bytes;

  static const zoomLevels = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 5.0];

  void zoomIn() {
    final next = zoomLevels.firstWhere((z) => z > _zoom + 0.01, orElse: () => zoomLevels.last);
    _state?._setZoom(next);
  }

  void zoomOut() {
    final previous = zoomLevels.lastWhere((z) => z < _zoom - 0.01, orElse: () => zoomLevels.first);
    _state?._setZoom(previous);
  }

  /// Volta a página a ocupar a largura do visualizador.
  void fitWidth() => _state?._setZoom(1);

  /// Ajusta o zoom para a página atual caber inteira na tela.
  void fitPage() => _state?._fitPage();

  void setZoom(double zoom) => _state?._setZoom(zoom);

  Future<void> goToPage(int pageNumber) async => _state?._goToPage(pageNumber);

  Future<void> nextPage() => goToPage(_pageNumber + 1);

  Future<void> previousPage() => goToPage(_pageNumber - 1);

  /// Abre o diálogo de impressão do sistema.
  Future<bool> printDocument() async => await _state?._print() ?? false;

  /// Abre o compartilhamento do sistema, com "Salvar em Arquivos", Google
  /// Drive etc. [bounds] é a área do botão, onde a janela se ancora no iPad.
  Future<bool> saveDocument({Rect? bounds}) async => await _state?._save(bounds) ?? false;

  /// Gera o documento de novo (ex.: depois de mudar os dados).
  Future<void> reload() async => _state?._load();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _update({int? pageCount, int? pageNumber, double? zoom, bool? fitsPage, bool? printing, bool? saving}) {
    // Impressão e compartilhamento podem terminar depois que a tela fechou.
    if (_disposed) return;
    var changed = false;
    if (pageCount != null && pageCount != _pageCount) {
      _pageCount = pageCount;
      changed = true;
    }
    if (pageNumber != null && pageNumber != _pageNumber) {
      _pageNumber = pageNumber;
      changed = true;
    }
    if (zoom != null && zoom != _zoom) {
      _zoom = zoom;
      changed = true;
    }
    if (fitsPage != null && fitsPage != _fitsPage) {
      _fitsPage = fitsPage;
      changed = true;
    }
    if (printing != null && printing != _printing) {
      _printing = printing;
      changed = true;
    }
    if (saving != null && saving != _saving) {
      _saving = saving;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

/// Visualizador de PDF com rolagem contínua, navegação entre páginas, zoom
/// (botões, pinça e toque duplo), impressão e salvamento.
///
/// ```dart
/// PdfDocumentViewer.document(doc)            // gera e exibe
/// PdfDocumentViewer.open(context, document: doc, title: 'Vendas')
/// ```
class PdfDocumentViewer extends StatefulWidget {
  /// Exibe um [PdfDocument], gerando o arquivo ao abrir.
  const PdfDocumentViewer.document(
    PdfDocument this.document, {
    super.key,
    this.title,
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.allowSaving = true,
    this.toolbarActions = const [],
    this.onClose,
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : bytes = null,
       build = null;

  /// Exibe um PDF já gerado (ou qualquer outro arquivo PDF).
  const PdfDocumentViewer.bytes(
    Uint8List this.bytes, {
    super.key,
    this.title,
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.allowSaving = true,
    this.toolbarActions = const [],
    this.onClose,
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : document = null,
       build = null;

  /// Exibe o PDF produzido por [build], chamado ao abrir e em `reload()`.
  const PdfDocumentViewer({
    super.key,
    required Future<Uint8List> Function() this.build,
    this.title,
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.allowSaving = true,
    this.toolbarActions = const [],
    this.onClose,
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : document = null,
       bytes = null;

  final PdfDocument? document;
  final Uint8List? bytes;
  final Future<Uint8List> Function()? build;

  /// Texto da barra superior. O padrão é [fileName].
  final String? title;

  /// Nome do arquivo ao imprimir, salvar ou compartilhar.
  final String fileName;

  final PdfDocumentViewerController? controller;

  /// Mostra as barras superior e inferior.
  final bool showToolbar;
  final bool allowPrinting;
  final bool allowSaving;

  /// Botões extras na barra superior, antes do botão de fechar. Use
  /// [PdfViewerToolbarButton] para manter o mesmo estilo.
  final List<Widget> toolbarActions;

  /// Quando informado, a barra superior mostra o botão de fechar.
  final VoidCallback? onClose;

  /// Cor atrás das páginas.
  final Color? backgroundColor;

  final PdfViewerBackend backend;

  /// Abre o visualizador em uma nova tela, com botão de fechar.
  static Future<void> open(
    BuildContext context, {
    PdfDocument? document,
    Uint8List? bytes,
    String? title,
    String fileName = 'documento.pdf',
    bool allowPrinting = true,
    bool allowSaving = true,
    List<Widget> toolbarActions = const [],
    PdfViewerBackend backend = PdfViewerBackend.printing,
  }) {
    assert((document == null) != (bytes == null), 'Informe document ou bytes');
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          void close() => Navigator.of(context).maybePop();
          return Scaffold(
            backgroundColor: _Palette.background,
            body: document != null
                ? PdfDocumentViewer.document(
                    document,
                    title: title,
                    fileName: fileName,
                    allowPrinting: allowPrinting,
                    allowSaving: allowSaving,
                    toolbarActions: toolbarActions,
                    onClose: close,
                    backend: backend,
                  )
                : PdfDocumentViewer.bytes(
                    bytes!,
                    title: title,
                    fileName: fileName,
                    allowPrinting: allowPrinting,
                    allowSaving: allowSaving,
                    toolbarActions: toolbarActions,
                    onClose: close,
                    backend: backend,
                  ),
          );
        },
      ),
    );
  }

  @override
  State<PdfDocumentViewer> createState() => _PdfDocumentViewerState();
}

class _PageEntry {
  _PageEntry(this.widthPoints, this.heightPoints, this.preview);

  final double widthPoints;
  final double heightPoints;

  /// Imagem de baixa resolução, exibida enquanto a nítida não fica pronta.
  final ui.Image preview;
  ui.Image? sharp;
  double sharpDpi = 0;

  void dispose() {
    preview.dispose();
    sharp?.dispose();
    sharp = null;
  }
}

class _PdfDocumentViewerState extends State<PdfDocumentViewer> {
  static const _previewDpi = 24.0;
  static const _padding = 24.0;
  static const _spacing = 16.0;
  static const _maxSharpPixels = 4096.0;

  PdfDocumentViewerController? _ownController;
  PdfDocumentViewerController get _controller =>
      widget.controller ?? (_ownController ??= PdfDocumentViewerController());

  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  Uint8List? _bytes;
  Object? _error;
  List<_PageEntry> _pages = const [];
  int _loadToken = 0;

  double _zoom = 1;
  double _pinchStartZoom = 1;
  Offset? _doubleTapPosition;
  Size _viewport = Size.zero;
  List<double> _tops = const [];
  double _pointsToPixels = 1;

  /// Página usada em "ajustar à página"; nulo quando o zoom é livre.
  int? _fitPageIndex;

  final Map<int, double> _wanted = {};
  final Map<int, double> _inFlight = {};
  bool _rasterBusy = false;

  @override
  void initState() {
    super.initState();
    _controller._state = this;
    _vertical.addListener(_updateCurrentPage);
    _load();
  }

  @override
  void didUpdateWidget(covariant PdfDocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._state = null;
      _controller._state = this;
    }
    if (oldWidget.document != widget.document || oldWidget.bytes != widget.bytes) _load();
  }

  @override
  void dispose() {
    _controller._state = null;
    _ownController?.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    _disposePages();
    super.dispose();
  }

  void _disposePages() {
    for (final page in _pages) {
      page.dispose();
    }
    _pages = const [];
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    if (_error != null || _pages.isNotEmpty) {
      setState(() {
        _error = null;
        _bytes = null;
      });
    }
    _disposePages();
    _wanted.clear();
    try {
      final bytes = widget.bytes ?? await (widget.document?.save() ?? widget.build!());
      final pages = <_PageEntry>[];
      await for (final image in widget.backend.rasterize(bytes, dpi: _previewDpi)) {
        pages.add(_PageEntry(image.width * 72 / _previewDpi, image.height * 72 / _previewDpi, image));
      }
      if (!mounted || token != _loadToken) {
        for (final page in pages) {
          page.dispose();
        }
        return;
      }
      if (pages.isEmpty) throw StateError('O PDF não tem páginas');
      if (_fitPageIndex != null && _fitPageIndex! >= pages.length) _fitPageIndex = pages.length - 1;
      setState(() {
        _bytes = bytes;
        _pages = pages;
      });
      _controller._update(pageCount: pages.length, pageNumber: 1, zoom: _zoom);
    } catch (error, stack) {
      debugPrint('lib_pdf: erro ao abrir o PDF: $error\n$stack');
      if (mounted && token == _loadToken) setState(() => _error = error);
    }
  }

  // ---------------------------------------------------------------------------
  // Zoom e navegação.

  double get _minZoom => PdfDocumentViewerController.zoomLevels.first;
  double get _maxZoom => PdfDocumentViewerController.zoomLevels.last;

  /// Pixels por ponto com zoom 1: página mais larga ocupando a largura
  /// disponível (até 900 px).
  double get _fitWidthScale {
    final widest = _pages.map((p) => p.widthPoints).reduce(math.max);
    return math.max(math.min(_viewport.width - _padding * 2, 900) / widest, 0.05);
  }

  double _fitPageZoom(int index) {
    final page = _pages[index];
    final scale = math.min(
      (_viewport.width - _padding * 2) / page.widthPoints,
      (_viewport.height - _padding * 2) / page.heightPoints,
    );
    return (scale / _fitWidthScale).clamp(_minZoom, _maxZoom);
  }

  void _setZoom(double zoom, {Offset? focal}) {
    if (_fitPageIndex != null) {
      _fitPageIndex = null;
      _controller._update(fitsPage: false);
    }
    final target = zoom.clamp(_minZoom, _maxZoom);
    if ((target - _zoom).abs() < 0.001 || _pages.isEmpty) return;
    final ratio = target / _zoom;
    final anchor = focal ?? Offset(_viewport.width / 2, _viewport.height / 3);
    final vertical = _vertical.hasClients ? _vertical.offset : 0.0;
    final horizontal = _horizontal.hasClients ? _horizontal.offset : 0.0;
    setState(() => _zoom = target);
    _controller._update(zoom: target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_vertical.hasClients) {
        final y = (vertical + anchor.dy - _padding) * ratio + _padding - anchor.dy;
        _vertical.jumpTo(y.clamp(0.0, _vertical.position.maxScrollExtent));
      }
      if (_horizontal.hasClients) {
        final x = (horizontal + anchor.dx) * ratio - anchor.dx;
        _horizontal.jumpTo(x.clamp(0.0, _horizontal.position.maxScrollExtent));
      }
    });
  }

  void _fitPage() {
    if (_pages.isEmpty || _viewport.isEmpty) return;
    final index = (_controller.pageNumber - 1).clamp(0, _pages.length - 1);
    final target = _fitPageZoom(index);
    setState(() {
      _fitPageIndex = index;
      _zoom = target;
    });
    _controller._update(zoom: target, fitsPage: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index >= _tops.length) return;
      if (_vertical.hasClients) {
        _vertical.jumpTo((_tops[index] - _padding).clamp(0.0, _vertical.position.maxScrollExtent));
      }
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    });
  }

  Future<void> _goToPage(int pageNumber) async {
    if (_pages.isEmpty || !_vertical.hasClients) return;
    final index = (pageNumber - 1).clamp(0, _pages.length - 1);
    final offset = (_tops[index] - _padding).clamp(0.0, _vertical.position.maxScrollExtent);
    _controller._update(pageNumber: index + 1);
    await _vertical.animateTo(offset, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void _updateCurrentPage() {
    if (_tops.isEmpty) return;
    // Página que ocupa o terço superior da tela.
    final y = _vertical.offset + _viewport.height / 3;
    var lo = 0;
    var hi = _tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (_vertical.position.pixels >= _vertical.position.maxScrollExtent - 1) lo = _tops.length - 1;
    _controller._update(pageNumber: lo + 1);
    _requestVisibleRasters();
  }

  Future<bool> _print() async {
    final bytes = _bytes;
    if (bytes == null || _controller.isPrinting) return false;
    _controller._update(printing: true);
    try {
      return await widget.backend.printPdf(bytes, name: widget.fileName);
    } catch (error) {
      _showError('Não foi possível imprimir: $error');
      return false;
    } finally {
      _controller._update(printing: false);
    }
  }

  Future<bool> _save(Rect? bounds) async {
    final bytes = _bytes;
    if (bytes == null || _controller.isSaving) return false;
    _controller._update(saving: true);
    try {
      return await widget.backend.sharePdf(bytes, name: widget.fileName, bounds: bounds);
    } catch (error) {
      _showError('Não foi possível salvar: $error');
      return false;
    } finally {
      _controller._update(saving: false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating, showCloseIcon: true),
    );
  }

  // ---------------------------------------------------------------------------
  // Renderização nítida das páginas visíveis.

  double get _targetDpi {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    // 1 ponto ocupa _pointsToPixels pixels lógicos; arredonda para evitar
    // renderizar de novo a cada pequeno passo de zoom.
    final dpi = _pointsToPixels * dpr * 72;
    return (dpi / 36).ceil() * 36;
  }

  void _requestVisibleRasters() {
    if (_pages.isEmpty || _tops.isEmpty || !_vertical.hasClients) return;
    final top = _vertical.offset - _viewport.height / 2;
    final bottom = _vertical.offset + _viewport.height * 1.5;
    final dpi = _targetDpi;
    for (var i = 0; i < _pages.length; i++) {
      final pageTop = _tops[i];
      final pageBottom = pageTop + _pages[i].heightPoints * _pointsToPixels;
      if (pageBottom < top || pageTop > bottom) continue;
      final page = _pages[i];
      final maxDpi = _maxSharpPixels / math.max(page.widthPoints, page.heightPoints) * 72;
      final wanted = math.min(dpi, maxDpi);
      final pending = _inFlight[i] ?? 0;
      if (page.sharpDpi + 1 < wanted && pending + 1 < wanted) _wanted[i] = wanted;
    }
    unawaited(_pumpRasters());
  }

  bool _isNearViewport(int index) {
    if (!_vertical.hasClients) return false;
    final pageTop = _tops[index];
    final pageBottom = pageTop + _pages[index].heightPoints * _pointsToPixels;
    return pageBottom >= _vertical.offset - _viewport.height && pageTop <= _vertical.offset + _viewport.height * 2;
  }

  Future<void> _pumpRasters() async {
    if (_rasterBusy) return;
    _rasterBusy = true;
    final token = _loadToken;
    final bytes = _bytes;
    try {
      while (_wanted.isNotEmpty && mounted && token == _loadToken && bytes != null) {
        // Prioriza a página em destaque.
        final current = _controller.pageNumber - 1;
        final index = _wanted.keys.reduce((a, b) => (a - current).abs() <= (b - current).abs() ? a : b);
        final dpi = _wanted.remove(index)!;
        if (index >= _pages.length || !_isNearViewport(index)) continue;
        List<ui.Image> images;
        _inFlight[index] = dpi;
        try {
          images = await widget.backend.rasterize(bytes, pages: [index], dpi: dpi).toList();
        } catch (error) {
          debugPrint('lib_pdf: erro ao renderizar a página ${index + 1}: $error');
          // Não tenta de novo nesta resolução; a prévia continua visível.
          if (index < _pages.length) _pages[index].sharpDpi = dpi;
          continue;
        } finally {
          _inFlight.remove(index);
        }
        if (!mounted || token != _loadToken || images.isEmpty) {
          for (final image in images) {
            image.dispose();
          }
          return;
        }
        final page = _pages[index];
        page.sharp?.dispose();
        page.sharp = images.first;
        page.sharpDpi = dpi;
        for (final extra in images.skip(1)) {
          extra.dispose();
        }
        _releaseFarImages();
        setState(() {});
      }
    } finally {
      _rasterBusy = false;
    }
  }

  /// Libera imagens nítidas de páginas distantes para limitar a memória.
  void _releaseFarImages() {
    final current = _controller.pageNumber - 1;
    for (var i = 0; i < _pages.length; i++) {
      if ((i - current).abs() > 4 && _pages[i].sharp != null) {
        _pages[i].sharp!.dispose();
        _pages[i].sharp = null;
        _pages[i].sharpDpi = 0;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Interface.

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.backgroundColor ?? _Palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showToolbar)
            PdfDocumentViewerToolbar(
              controller: _controller,
              title: widget.title ?? widget.fileName,
              allowPrinting: widget.allowPrinting,
              allowSaving: widget.allowSaving,
              actions: widget.toolbarActions,
              onClose: widget.onClose,
            ),
          Expanded(child: _content(context)),
          if (widget.showToolbar) PdfDocumentViewerNavigationBar(controller: _controller),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    const messageStyle = TextStyle(fontSize: 14, color: _Palette.muted);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: _Palette.pdf),
              const SizedBox(height: 12),
              Text('Não foi possível abrir o PDF.\n$_error', textAlign: TextAlign.center, style: messageStyle),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Tentar de novo')),
            ],
          ),
        ),
      );
    }
    if (_pages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Gerando PDF…', style: messageStyle)],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        if (_fitPageIndex case final index?) {
          // Mantém a página inteira visível quando a janela muda de tamanho.
          final zoom = _fitPageZoom(index);
          if ((zoom - _zoom).abs() > 0.001) {
            _zoom = zoom;
            WidgetsBinding.instance.addPostFrameCallback((_) => _controller._update(zoom: zoom));
          }
        }
        final widest = _pages.map((p) => p.widthPoints).reduce(math.max);
        _pointsToPixels = _fitWidthScale * _zoom;

        final tops = <double>[];
        var y = _padding;
        for (final page in _pages) {
          tops.add(y);
          y += page.heightPoints * _pointsToPixels + _spacing;
        }
        _tops = tops;
        final contentWidth = math.max(_viewport.width, widest * _pointsToPixels + _padding * 2);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _requestVisibleRasters();
        });

        final noScrollbars = ScrollConfiguration.of(context).copyWith(scrollbars: false);
        return GestureDetector(
          onScaleStart: (details) {
            if (details.pointerCount >= 2) _pinchStartZoom = _zoom;
          },
          onScaleUpdate: (details) {
            if (details.pointerCount < 2) return;
            _setZoom(_pinchStartZoom * details.scale, focal: details.localFocalPoint);
          },
          onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
          onDoubleTap: () => _setZoom(_zoom < 1.5 ? 2 : 1, focal: _doubleTapPosition),
          child: Scrollbar(
            controller: _horizontal,
            notificationPredicate: (notification) => notification.depth == 0,
            child: Scrollbar(
              controller: _vertical,
              notificationPredicate: (notification) => notification.depth == 1,
              child: ScrollConfiguration(
                behavior: noScrollbars,
                child: SingleChildScrollView(
                  controller: _horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: contentWidth,
                    height: _viewport.height,
                    child: ListView.builder(
                      controller: _vertical,
                      padding: const EdgeInsets.symmetric(vertical: _padding),
                      itemCount: _pages.length,
                      itemExtentBuilder: (index, _) =>
                          _pages[index].heightPoints * _pointsToPixels + (index < _pages.length - 1 ? _spacing : 0),
                      itemBuilder: (context, index) => _pageView(index),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pageView(int index) {
    final page = _pages[index];
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        key: ValueKey('lib_pdf_page_$index'),
        width: page.widthPoints * _pointsToPixels,
        height: page.heightPoints * _pointsToPixels,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(2),
          boxShadow: const [
            BoxShadow(color: Color(0x0F101828), blurRadius: 3, offset: Offset(0, 1)),
            BoxShadow(color: Color(0x14101828), blurRadius: 16, offset: Offset(0, 6)),
          ],
        ),
        child: RawImage(image: page.sharp ?? page.preview, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
      ),
    );
  }
}

/// Barra superior do [PdfDocumentViewer]: nome do arquivo, impressão, zoom,
/// salvar, ajuste da página e fechar.
///
/// Em telas estreitas os botões de zoom e de ajuste ficam só na barra
/// inferior ([PdfDocumentViewerNavigationBar]).
class PdfDocumentViewerToolbar extends StatelessWidget {
  const PdfDocumentViewerToolbar({
    super.key,
    required this.controller,
    required this.title,
    this.allowPrinting = true,
    this.allowSaving = true,
    this.actions = const [],
    this.onClose,
  });

  final PdfDocumentViewerController controller;
  final String title;
  final bool allowPrinting;
  final bool allowSaving;
  final List<Widget> actions;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Material(
        color: _Palette.bar,
        shape: const Border(bottom: BorderSide(color: _Palette.divider)),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;
              final size = compact ? 36.0 : 40.0;
              final gap = compact ? 6.0 : 8.0;
              return Container(
                height: compact ? 56 : 68,
                padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 20),
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final ready = controller.isReady;
                    PdfViewerToolbarButton button(String tooltip, IconData icon, VoidCallback? onPressed) =>
                        PdfViewerToolbarButton(tooltip: tooltip, icon: icon, onPressed: onPressed, size: size);
                    // Ordem: imprimir, ajustar à página/largura, diminuir zoom,
                    // aumentar zoom, salvar, extras e fechar.
                    final buttons = [
                      if (allowPrinting)
                        button('Imprimir', Icons.print_outlined, ready && !controller.isPrinting ? controller.printDocument : null),
                      if (!compact) ...[
                        controller.fitsPage
                            ? button('Ajustar à largura', Icons.width_full_outlined, ready ? controller.fitWidth : null)
                            : button('Ajustar à página', Icons.fit_screen_outlined, ready ? controller.fitPage : null),
                        button(
                          'Diminuir zoom',
                          Icons.zoom_out,
                          ready && controller.zoom > PdfDocumentViewerController.zoomLevels.first ? controller.zoomOut : null,
                        ),
                        button(
                          'Aumentar zoom',
                          Icons.zoom_in,
                          ready && controller.zoom < PdfDocumentViewerController.zoomLevels.last ? controller.zoomIn : null,
                        ),
                      ],
                      if (allowSaving)
                        Builder(
                          builder: (context) => button(
                            'Salvar',
                            Icons.save_outlined,
                            ready && !controller.isSaving
                                ? () => controller.saveDocument(bounds: _globalBounds(context))
                                : null,
                          ),
                        ),
                      ...actions,
                    ];
                    return Row(
                      children: [
                        _PdfBadge(size: size),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: compact ? 15 : 17, fontWeight: FontWeight.w500, color: _Palette.text),
                          ),
                        ),
                        for (final widget in buttons) ...[SizedBox(width: gap), widget],
                        if (onClose != null) ...[
                          SizedBox(width: compact ? 10 : 20),
                          button('Fechar', Icons.close, onClose),
                        ],
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static Rect? _globalBounds(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}

/// Barra inferior do [PdfDocumentViewer]: página atual (editável) e zoom.
class PdfDocumentViewerNavigationBar extends StatelessWidget {
  const PdfDocumentViewerNavigationBar({super.key, required this.controller});

  final PdfDocumentViewerController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _Palette.bar,
      shape: const Border(top: BorderSide(color: _Palette.divider)),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          // Centralizada quando cabe; rola na horizontal em telas muito estreitas.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final ready = controller.isReady;
                    final page = controller.pageNumber;
                    final count = controller.pageCount;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        PdfViewerToolbarButton(
                          tooltip: 'Página anterior',
                          icon: Icons.chevron_left,
                          outlined: false,
                          onPressed: ready && page > 1 ? controller.previousPage : null,
                        ),
                        const SizedBox(width: 8),
                        _PageField(controller: controller),
                        const SizedBox(width: 8),
                        PdfViewerToolbarButton(
                          tooltip: 'Próxima página',
                          icon: Icons.chevron_right,
                          outlined: false,
                          onPressed: ready && page < count ? controller.nextPage : null,
                        ),
                        Container(
                          width: 1,
                          height: 28,
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          color: _Palette.divider,
                        ),
                        _ZoomMenu(controller: controller),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Botão no estilo das barras do [PdfDocumentViewer], para usar em
/// `toolbarActions`.
class PdfViewerToolbarButton extends StatelessWidget {
  const PdfViewerToolbarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.outlined = true,
    this.size = 40,
  });

  final IconData icon;
  final String tooltip;

  /// Nulo desabilita o botão.
  final VoidCallback? onPressed;

  /// Com borda (barra superior) ou sem (setas da barra inferior).
  final bool outlined;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: SizedBox.square(
          dimension: size,
          child: Material(
            color: Colors.transparent,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: outlined ? const BorderSide(color: _Palette.outline) : BorderSide.none,
            ),
            child: InkWell(
              onTap: onPressed,
              hoverColor: _Palette.hover,
              highlightColor: _Palette.hover,
              splashColor: _Palette.splash,
              child: Icon(icon, size: outlined ? size * 0.55 : size * 0.65, color: enabled ? _Palette.icon : _Palette.disabled),
            ),
          ),
        ),
      ),
    );
  }
}

class _PdfBadge extends StatelessWidget {
  const _PdfBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _Palette.pdf, borderRadius: BorderRadius.circular(8)),
      child: Icon(Icons.picture_as_pdf_outlined, color: Colors.white, size: size * 0.6),
    );
  }
}

/// Caixa "3 / 15": digitar um número e confirmar (ou tocar fora) leva à página.
class _PageField extends StatefulWidget {
  const _PageField({required this.controller});

  final PdfDocumentViewerController controller;

  @override
  State<_PageField> createState() => _PageFieldState();
}

class _PageFieldState extends State<_PageField> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _focus.addListener(_focusChanged);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _PageField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!mounted) return;
    if (_focus.hasFocus) {
      // Depois do toque posicionar o cursor: seleciona tudo para digitar por cima.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _focus.hasFocus) _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
      });
    } else {
      // Confirmar ou tocar fora leva à página digitada.
      final page = int.tryParse(_text.text);
      if (page != null && page != widget.controller.pageNumber) widget.controller.goToPage(page);
      _sync();
    }
    setState(() {});
  }

  /// Mostra a página atual, exceto enquanto o usuário digita.
  void _sync() {
    if (_focus.hasFocus) return;
    final value = widget.controller.isReady ? '${widget.controller.pageNumber}' : '';
    if (_text.text != value) _text.text = value;
  }


  @override
  Widget build(BuildContext context) {
    final ready = widget.controller.isReady;
    final count = widget.controller.pageCount;
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _Palette.text);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: _Palette.bar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _focus.hasFocus ? Theme.of(context).colorScheme.primary : _Palette.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10.0 * math.max(2, '$count'.length) + 4,
            child: TextField(
              key: const ValueKey('lib_pdf_page_field'),
              controller: _text,
              focusNode: _focus,
              enabled: ready,
              textAlign: TextAlign.center,
              textAlignVertical: TextAlignVertical.center,
              // Com `signed`, o teclado do iPhone tem a tecla de confirmar.
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              textInputAction: TextInputAction.go,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: style,
              cursorHeight: 18,
              decoration: const InputDecoration.collapsed(hintText: null),
              onSubmitted: (_) => _focus.unfocus(),
              onTapOutside: (_) => _focus.unfocus(),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            ready ? '/ $count' : '/ –',
            style: style.copyWith(fontWeight: FontWeight.w400, color: _Palette.muted),
          ),
        ],
      ),
    );
  }
}

/// "100% ⌄": abre a lista de níveis de zoom e "Ajustar à página".
class _ZoomMenu extends StatelessWidget {
  const _ZoomMenu({required this.controller});

  final PdfDocumentViewerController controller;

  @override
  Widget build(BuildContext context) {
    final ready = controller.isReady;
    return PopupMenuButton<double>(
      tooltip: 'Zoom',
      enabled: ready,
      color: _Palette.bar,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _Palette.divider),
      ),
      // Valor negativo = ajustar à página.
      onSelected: (value) => value < 0 ? controller.fitPage() : controller.setZoom(value),
      itemBuilder: (context) => [
        _item(-1, 'Ajustar à página', selected: controller.fitsPage),
        const PopupMenuDivider(),
        for (final level in PdfDocumentViewerController.zoomLevels)
          _item(
            level,
            '${(level * 100).round()}%',
            selected: !controller.fitsPage && (controller.zoom - level).abs() < 0.001,
          ),
      ],
      child: Container(
        height: 36,
        constraints: const BoxConstraints(minWidth: 92),
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: BoxDecoration(
          border: Border.all(color: _Palette.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${(controller.zoom * 100).round()}%',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: ready ? _Palette.text : _Palette.disabled,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.keyboard_arrow_down, size: 20, color: ready ? _Palette.icon : _Palette.disabled),
          ],
        ),
      ),
    );
  }

  static PopupMenuItem<double> _item(double value, String label, {required bool selected}) {
    return PopupMenuItem(
      value: value,
      height: 40,
      child: Row(
        children: [
          SizedBox(width: 26, child: selected ? const Icon(Icons.check, size: 18, color: _Palette.icon) : null),
          Text(
            label,
            style: TextStyle(color: _Palette.text, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
          ),
        ],
      ),
    );
  }
}
