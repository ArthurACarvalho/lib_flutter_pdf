import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../pdf_document.dart';
import 'viewer_backend.dart';

/// Controla um [PdfDocumentViewer] de fora (ex.: barra de ferramentas própria).
class PdfDocumentViewerController extends ChangeNotifier {
  _PdfDocumentViewerState? _state;

  int _pageCount = 0;
  int _pageNumber = 1;
  double _zoom = 1;
  bool _printing = false;

  /// Se o documento já foi gerado e as páginas estão prontas.
  bool get isReady => _pageCount > 0;

  int get pageCount => _pageCount;

  /// Página em destaque na tela (começa em 1).
  int get pageNumber => _pageNumber;

  /// 1.0 = página ajustada à largura do visualizador.
  double get zoom => _zoom;

  bool get isPrinting => _printing;

  /// Bytes do PDF exibido (nulo enquanto é gerado).
  Uint8List? get bytes => _state?._bytes;

  static const zoomLevels = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 5.0];

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

  void setZoom(double zoom) => _state?._setZoom(zoom);

  Future<void> goToPage(int pageNumber) async => _state?._goToPage(pageNumber);

  Future<void> nextPage() => goToPage(_pageNumber + 1);

  Future<void> previousPage() => goToPage(_pageNumber - 1);

  /// Abre o diálogo de impressão do sistema.
  Future<bool> printDocument() async => await _state?._print() ?? false;

  /// Gera o documento de novo (ex.: depois de mudar os dados).
  Future<void> reload() async => _state?._load();

  void _update({int? pageCount, int? pageNumber, double? zoom, bool? printing}) {
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
    if (printing != null && printing != _printing) {
      _printing = printing;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

/// Visualizador de PDF com rolagem contínua, navegação entre páginas, zoom
/// (botões, pinça e toque duplo) e impressão.
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
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.toolbarActions = const [],
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : bytes = null,
       build = null;

  /// Exibe um PDF já gerado (ou qualquer outro arquivo PDF).
  const PdfDocumentViewer.bytes(
    Uint8List this.bytes, {
    super.key,
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.toolbarActions = const [],
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : document = null,
       build = null;

  /// Exibe o PDF produzido por [build], chamado ao abrir e em `reload()`.
  const PdfDocumentViewer({
    super.key,
    required Future<Uint8List> Function() this.build,
    this.fileName = 'documento.pdf',
    this.controller,
    this.showToolbar = true,
    this.allowPrinting = true,
    this.toolbarActions = const [],
    this.backgroundColor,
    this.backend = PdfViewerBackend.printing,
  }) : document = null,
       bytes = null;

  final PdfDocument? document;
  final Uint8List? bytes;
  final Future<Uint8List> Function()? build;

  /// Nome sugerido ao imprimir/salvar pelo diálogo do sistema.
  final String fileName;

  final PdfDocumentViewerController? controller;
  final bool showToolbar;
  final bool allowPrinting;

  /// Botões extras no fim da barra de ferramentas.
  final List<Widget> toolbarActions;

  /// Cor atrás das páginas.
  final Color? backgroundColor;

  final PdfViewerBackend backend;

  /// Abre o visualizador em uma nova tela.
  static Future<void> open(
    BuildContext context, {
    PdfDocument? document,
    Uint8List? bytes,
    String title = 'PDF',
    String fileName = 'documento.pdf',
    bool allowPrinting = true,
    List<Widget> toolbarActions = const [],
    PdfViewerBackend backend = PdfViewerBackend.printing,
  }) {
    assert((document == null) != (bytes == null), 'Informe document ou bytes');
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: document != null
              ? PdfDocumentViewer.document(
                  document,
                  fileName: fileName,
                  allowPrinting: allowPrinting,
                  toolbarActions: toolbarActions,
                  backend: backend,
                )
              : PdfDocumentViewer.bytes(
                  bytes!,
                  fileName: fileName,
                  allowPrinting: allowPrinting,
                  toolbarActions: toolbarActions,
                  backend: backend,
                ),
        ),
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
  static const _padding = 16.0;
  static const _spacing = 12.0;
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

  void _setZoom(double zoom, {Offset? focal}) {
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
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Não foi possível imprimir: $error')));
      }
      return false;
    } finally {
      _controller._update(printing: false);
    }
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
    final theme = Theme.of(context);
    final background = widget.backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
    return ColoredBox(
      color: background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showToolbar)
            PdfDocumentViewerToolbar(
              controller: _controller,
              allowPrinting: widget.allowPrinting,
              actions: widget.toolbarActions,
            ),
          Expanded(child: _content(context)),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text('Não foi possível abrir o PDF.\n$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
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
          children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Gerando PDF…')],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        final widest = _pages.map((p) => p.widthPoints).reduce(math.max);
        // Zoom 1 = página mais larga ocupando a largura disponível (até 900 px).
        final fit = math.min(_viewport.width - _padding * 2, 900) / widest;
        _pointsToPixels = math.max(fit, 0.05) * _zoom;

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
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: RawImage(image: page.sharp ?? page.preview, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
      ),
    );
  }
}

/// Barra padrão do [PdfDocumentViewer]: páginas, zoom e impressão.
class PdfDocumentViewerToolbar extends StatelessWidget {
  const PdfDocumentViewerToolbar({
    super.key,
    required this.controller,
    this.allowPrinting = true,
    this.actions = const [],
  });

  final PdfDocumentViewerController controller;
  final bool allowPrinting;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 1,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final ready = controller.isReady;
          final page = controller.pageNumber;
          final count = controller.pageCount;
          // Centralizada quando cabe; rola na horizontal em telas estreitas.
          return LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Página anterior',
                      icon: const Icon(Icons.keyboard_arrow_up),
                      onPressed: ready && page > 1 ? controller.previousPage : null,
                    ),
                    TextButton(
                      onPressed: ready ? () => _askPage(context) : null,
                      child: Text(ready ? '$page / $count' : '– / –'),
                    ),
                    IconButton(
                      tooltip: 'Próxima página',
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: ready && page < count ? controller.nextPage : null,
                    ),
                    const _Separator(),
                    IconButton(
                      tooltip: 'Diminuir zoom',
                      icon: const Icon(Icons.zoom_out),
                      onPressed: ready && controller.zoom > PdfDocumentViewerController.zoomLevels.first
                          ? controller.zoomOut
                          : null,
                    ),
                    Tooltip(
                      message: 'Ajustar à largura',
                      child: TextButton(
                        onPressed: ready ? controller.fitWidth : null,
                        child: Text('${(controller.zoom * 100).round()}%'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Aumentar zoom',
                      icon: const Icon(Icons.zoom_in),
                      onPressed: ready && controller.zoom < PdfDocumentViewerController.zoomLevels.last
                          ? controller.zoomIn
                          : null,
                    ),
                    if (allowPrinting) ...[
                      const _Separator(),
                      IconButton(
                        tooltip: 'Imprimir',
                        icon: const Icon(Icons.print),
                        onPressed: ready && !controller.isPrinting ? controller.printDocument : null,
                      ),
                    ],
                    ...actions,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _askPage(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) => _GoToPageDialog(current: controller.pageNumber, count: controller.pageCount),
    );
    if (result != null) await controller.goToPage(result);
  }
}

class _GoToPageDialog extends StatefulWidget {
  const _GoToPageDialog({required this.current, required this.count});

  final int current;
  final int count;

  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  // O controller vive com o diálogo: a animação de saída ainda o usa.
  late final _text = TextEditingController(text: '${widget.current}');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(int.tryParse(_text.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ir para a página'),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(helperText: 'De 1 a ${widget.count}'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _submit, child: const Text('Ir')),
      ],
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 24, child: VerticalDivider(width: 12, color: Theme.of(context).dividerColor));
}
