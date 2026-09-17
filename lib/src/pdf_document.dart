import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/content.dart';
import 'core/document_builder.dart';
import 'font/font_registry.dart';
import 'layout/break_finder.dart';
import 'layout/page_format.dart';
import 'layout/pdf_context.dart';
import 'render/offscreen_tree.dart';
import 'render/pdf_canvas.dart';
import 'render/render_session.dart';
import 'render/vector_context.dart';

/// Constrói um widget para uma página (cabeçalho, rodapé, fundo…).
typedef PdfWidgetBuilder = Widget Function(PdfContext context);

/// Base comum de [PdfPage] e [PdfMultiPage].
sealed class PdfBasePage {
  const PdfBasePage({
    this.format = PdfPageFormat.a4,
    this.margin = const EdgeInsets.all(36),
    this.background,
    this.foreground,
    this.theme,
  });

  final PdfPageFormat format;
  final EdgeInsets margin;

  /// Desenhado atrás do conteúdo, ocupando a página inteira (ex.: marca d'água).
  final PdfWidgetBuilder? background;

  /// Desenhado na frente do conteúdo, ocupando a página inteira.
  final PdfWidgetBuilder? foreground;

  /// Tema específico destas páginas (padrão: o do documento).
  final ThemeData? theme;
}

/// Uma única página: [build] recebe exatamente a área interna às margens,
/// como uma tela do app.
class PdfPage extends PdfBasePage {
  const PdfPage({super.format, super.margin, super.background, super.foreground, super.theme, required this.build});

  final PdfWidgetBuilder build;
}

/// Conteúdo que flui por quantas páginas forem necessárias.
///
/// Os widgets de [build] são empilhados verticalmente na largura útil da
/// página e cortados entre páginas apenas em pontos seguros: entre filhos de
/// `Column`/`Row`/`Wrap`, entre linhas de `Table` e entre linhas de texto.
class PdfMultiPage extends PdfBasePage {
  const PdfMultiPage({
    super.format,
    super.margin,
    super.background,
    super.foreground,
    super.theme,
    this.header,
    this.footer,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.maxPages = 1000,
    required this.build,
  });

  final PdfWidgetBuilder? header;
  final PdfWidgetBuilder? footer;

  /// Alinhamento horizontal dos itens de [build].
  final CrossAxisAlignment crossAxisAlignment;

  /// Limite de segurança contra conteúdo que nunca termina de paginar.
  final int maxPages;

  final List<Widget> Function(PdfContext context) build;
}

/// Documento PDF escrito com widgets do Flutter.
///
/// ```dart
/// final doc = PdfDocument(title: 'Vendas');
/// doc.addPage(PdfMultiPage(build: (ctx) => [Text('Olá')]));
/// final bytes = await doc.save();
/// ```
class PdfDocument {
  PdfDocument({
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.theme,
    this.fontFamily,
    this.fonts = const [],
    this.locale = const Locale('en', 'US'),
    this.localizationsDelegates,
    this.textDirection = TextDirection.ltr,
    this.rasterPixelRatio = 3,
    this.imageTimeout = const Duration(seconds: 10),
    this.settleDuration = Duration.zero,
  });

  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;
  final String? creator;

  /// Tema aplicado aos widgets (padrão: `ThemeData()` claro).
  final ThemeData? theme;

  /// Família de fonte padrão. Sem valor, usa a Roboto embutida na lib (ou a
  /// família definida no [theme], quando for uma fonte do app).
  final String? fontFamily;

  /// Fontes extras carregadas para o relatório.
  final List<PdfFont> fonts;

  final Locale locale;

  /// Delegates de localização (ex.: `GlobalMaterialLocalizations.delegates`
  /// para textos padrão do Material em português).
  final List<LocalizationsDelegate<dynamic>>? localizationsDelegates;

  final TextDirection textDirection;

  /// Pixels por ponto usados no que precisa virar imagem.
  final double rasterPixelRatio;

  /// Tempo máximo esperando imagens (`Image.network`, `Image.asset`) carregarem.
  final Duration imageTimeout;

  /// Espera extra antes de capturar, para animações terminarem. Com zero, as
  /// animações ficam desligadas (`TickerMode`).
  final Duration settleDuration;

  final List<PdfBasePage> _pages = [];

  void addPage(PdfBasePage page) => _pages.add(page);

  /// Gera o arquivo PDF.
  Future<Uint8List> save() async {
    final registry = FontRegistry();
    await registry.init(fonts: fonts);
    final session = PdfRenderSession(doc: PdfDocumentBuilder(), fonts: registry, rasterPixelRatio: rasterPixelRatio);

    final prepared = <_PreparedSection>[];
    try {
      // Fase 1: layout e paginação (o total de páginas ainda é desconhecido).
      var pageCount = 0;
      for (final page in _pages) {
        final section = switch (page) {
          PdfPage() => _SinglePageSection(this, page),
          PdfMultiPage() => _MultiPageSection(this, page),
        };
        prepared.add(section);
        await section.layout(session, firstPageNumber: pageCount + 1);
        pageCount += section.pageCount;
      }

      // Fase 2: pintura com numeração final.
      var pageNumber = 1;
      for (final section in prepared) {
        await section.paint(session, firstPageNumber: pageNumber, pagesCount: pageCount);
        pageNumber += section.pageCount;
      }
    } finally {
      for (final section in prepared) {
        section.dispose();
      }
    }

    await session.runJobs();
    return session.doc.finish(
      PdfInfo(title: title, author: author, subject: subject, keywords: keywords, creator: creator),
    );
  }

  static const _platformFamilies = {
    null,
    'Roboto',
    '.SF UI Display',
    '.SF UI Text',
    '.AppleSystemUIFont',
    'CupertinoSystemDisplay',
    'CupertinoSystemText',
    'Segoe UI',
    'Ubuntu',
  };

  ThemeData _themeFor(PdfBasePage page) {
    final base = page.theme ?? theme ?? ThemeData();
    final current = base.textTheme.bodyMedium?.fontFamily;
    final family = fontFamily ?? (_platformFamilies.contains(current) ? FontRegistry.defaultFamily : null);
    if (family == null) return base;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: family),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    );
  }

  Widget _environment(PdfBasePage page, PdfContext ctx, Widget child) {
    final themeData = _themeFor(page);
    return MediaQuery(
      data: MediaQueryData(
        size: page.format.size,
        devicePixelRatio: 3,
        textScaler: TextScaler.noScaling,
        disableAnimations: settleDuration == Duration.zero,
      ),
      child: Directionality(
        textDirection: textDirection,
        child: Localizations(
          locale: locale,
          delegates:
              localizationsDelegates ??
              const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
          child: Theme(
            data: themeData,
            child: TickerMode(
              enabled: settleDuration > Duration.zero,
              child: PdfPageScope(
                pdf: ctx,
                child: Material(
                  type: MaterialType.transparency,
                  textStyle: themeData.textTheme.bodyMedium,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------

abstract class _PreparedSection {
  _PreparedSection(this.document);

  final PdfDocument document;
  final List<OffscreenTree> _trees = [];

  int get pageCount;

  Future<void> layout(PdfRenderSession session, {required int firstPageNumber});

  Future<void> paint(PdfRenderSession session, {required int firstPageNumber, required int pagesCount});

  OffscreenTree newTree(BoxConstraints constraints) {
    final tree = OffscreenTree(constraints: constraints);
    _trees.add(tree);
    return tree;
  }

  Future<void> settle(OffscreenTree tree, PdfRenderSession session) async {
    await tree.settle(imageTimeout: document.imageTimeout, settle: document.settleDuration);
    await session.fonts.ensureFamilies(tree.collectFontFamilies());
  }

  /// Monta, espera e mede um widget com largura [width] e altura livre.
  Future<OffscreenTree> buildLoose(
    PdfBasePage page,
    PdfContext ctx,
    Widget widget,
    PdfRenderSession session, {
    required double width,
    OffscreenTree? reuse,
  }) async {
    final tree = reuse ?? newTree(BoxConstraints(minWidth: width, maxWidth: width));
    tree.setWidget(document._environment(page, ctx, widget));
    await settle(tree, session);
    return tree;
  }

  PdfCanvas startPage(PdfRenderSession session, PdfContent content, PdfPageFormat format) {
    // Coordenadas do Flutter: origem no topo, y para baixo.
    content.transform(1, 0, 0, -1, 0, format.height);
    return PdfCanvas(session: session, content: content, deviceClip: Offset.zero & format.size);
  }

  void paintTree(PdfCanvas canvas, RenderBox? root, {required Rect clip, required Offset origin}) {
    if (root == null || !root.hasSize) return;
    canvas.save();
    canvas.clipRect(clip);
    canvas.translate(origin.dx, origin.dy);
    VectorPaintingContext(canvas, Offset.zero & root.size).paintRoot(root, Offset.zero);
    canvas.restore();
  }

  Future<void> paintDecorations(
    PdfRenderSession session,
    PdfCanvas canvas,
    PdfBasePage page,
    PdfContext ctx, {
    required bool foreground,
  }) async {
    final builder = foreground ? page.foreground : page.background;
    if (builder == null) return;
    final tree = newTree(BoxConstraints.tight(page.format.size));
    tree.setWidget(document._environment(page, ctx, builder(ctx)));
    await settle(tree, session);
    paintTree(canvas, tree.root, clip: Offset.zero & page.format.size, origin: Offset.zero);
    tree.dispose();
    _trees.remove(tree);
  }

  void dispose() {
    for (final tree in _trees) {
      tree.dispose();
    }
    _trees.clear();
  }
}

class _SinglePageSection extends _PreparedSection {
  _SinglePageSection(super.document, this.page);

  final PdfPage page;

  @override
  int get pageCount => 1;

  @override
  Future<void> layout(PdfRenderSession session, {required int firstPageNumber}) async {}

  @override
  Future<void> paint(PdfRenderSession session, {required int firstPageNumber, required int pagesCount}) async {
    final format = page.format;
    final ctx = PdfContext(pageNumber: firstPageNumber, pagesCount: pagesCount, format: format);
    final area = page.margin.deflateRect(Offset.zero & format.size);
    final tree = newTree(BoxConstraints.tight(area.size));
    tree.setWidget(document._environment(page, ctx, page.build(ctx)));
    await settle(tree, session);

    final content = PdfContent();
    final canvas = startPage(session, content, format);
    await paintDecorations(session, canvas, page, ctx, foreground: false);
    paintTree(canvas, tree.root, clip: area, origin: area.topLeft);
    await paintDecorations(session, canvas, page, ctx, foreground: true);
    session.doc.addPage(width: format.width, height: format.height, content: content);
  }
}

class _Slice {
  _Slice(this.top, this.bottom, this.header, this.headerHeight, this.footerHeight);

  final double top;
  final double bottom;
  final RepeatHeaderRegion? header;
  final double headerHeight;
  final double footerHeight;
}

class _MultiPageSection extends _PreparedSection {
  _MultiPageSection(super.document, this.page);

  final PdfMultiPage page;
  late OffscreenTree _body;
  OffscreenTree? _header;
  OffscreenTree? _footer;
  final List<_Slice> _slices = [];

  @override
  int get pageCount => _slices.length;

  Rect get _area => page.margin.deflateRect(Offset.zero & page.format.size);

  @override
  Future<void> layout(PdfRenderSession session, {required int firstPageNumber}) async {
    final area = _area;
    final ctx = PdfContext(pageNumber: firstPageNumber, pagesCount: 0, format: page.format);
    _body = await buildLoose(
      page,
      ctx,
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: page.crossAxisAlignment, children: page.build(ctx)),
      session,
      width: area.width,
    );
    final root = _body.root;
    if (root == null) return;
    final analysis = BreakAnalysis.of(root);

    var y = 0.0;
    var pageNumber = firstPageNumber;
    const eps = 0.01;
    do {
      final pageCtx = PdfContext(pageNumber: pageNumber, pagesCount: 0, format: page.format);
      final headerHeight = await _measure(session, page.header, pageCtx, header: true);
      final footerHeight = await _measure(session, page.footer, pageCtx, header: false);
      final available = area.height - headerHeight - footerHeight;
      if (available <= 1) {
        throw StateError('lib_pdf: cabeçalho e rodapé ocupam a página inteira');
      }

      final repeat = analysis.headerFor(y);
      final reserved = repeat != null && repeat.headerHeight < available / 2 ? repeat.headerHeight : 0.0;
      final limit = y + available - reserved;

      double end;
      final forced = analysis.forcedBreakIn(y, limit);
      if (forced != null) {
        end = forced;
      } else if (limit >= analysis.height - eps) {
        end = analysis.height;
      } else {
        final candidate = analysis.lastBreakIn(y, limit);
        if (candidate != null) {
          end = candidate;
        } else {
          end = limit;
          debugPrint(
            'lib_pdf: conteúdo mais alto que a página sem ponto de quebra; '
            'cortando em ${limit.toStringAsFixed(1)} (página $pageNumber).',
          );
        }
      }

      _slices.add(_Slice(y, end, reserved > 0 ? repeat : null, headerHeight, footerHeight));
      y = end;
      pageNumber++;
      if (_slices.length >= page.maxPages) {
        debugPrint('lib_pdf: limite de ${page.maxPages} páginas atingido.');
        break;
      }
    } while (y < analysis.height - eps);
  }

  Future<double> _measure(
    PdfRenderSession session,
    PdfWidgetBuilder? builder,
    PdfContext ctx, {
    required bool header,
  }) async {
    if (builder == null) return 0;
    final width = _area.width;
    final tree = await buildLoose(page, ctx, builder(ctx), session, width: width, reuse: header ? _header : _footer);
    if (header) {
      _header = tree;
    } else {
      _footer = tree;
    }
    return tree.root?.size.height ?? 0;
  }

  @override
  Future<void> paint(PdfRenderSession session, {required int firstPageNumber, required int pagesCount}) async {
    final area = _area;
    final format = page.format;
    for (var i = 0; i < _slices.length; i++) {
      final slice = _slices[i];
      final ctx = PdfContext(pageNumber: firstPageNumber + i, pagesCount: pagesCount, format: format);
      final content = PdfContent();
      final canvas = startPage(session, content, format);
      await paintDecorations(session, canvas, page, ctx, foreground: false);

      if (page.header != null) {
        await _measure(session, page.header, ctx, header: true);
        final height = math.max(slice.headerHeight, _header!.root?.size.height ?? 0);
        paintTree(
          canvas,
          _header!.root,
          clip: Rect.fromLTWH(area.left, area.top, area.width, height),
          origin: area.topLeft,
        );
      }

      final bodyTop = area.top + slice.headerHeight;
      var contentTop = bodyTop;
      final repeat = slice.header;
      if (repeat != null) {
        paintTree(
          canvas,
          _body.root,
          clip: Rect.fromLTWH(area.left, bodyTop, area.width, repeat.headerHeight),
          origin: Offset(area.left, bodyTop - repeat.headerTop),
        );
        contentTop += repeat.headerHeight;
      }
      paintTree(
        canvas,
        _body.root,
        clip: Rect.fromLTWH(area.left, contentTop, area.width, slice.bottom - slice.top),
        origin: Offset(area.left, contentTop - slice.top),
      );

      if (page.footer != null) {
        await _measure(session, page.footer, ctx, header: false);
        final height = _footer!.root?.size.height ?? 0;
        final top = area.bottom - math.max(height, slice.footerHeight);
        paintTree(
          canvas,
          _footer!.root,
          clip: Rect.fromLTWH(area.left, top, area.width, height),
          origin: Offset(area.left, top),
        );
      }

      await paintDecorations(session, canvas, page, ctx, foreground: true);
      session.doc.addPage(width: format.width, height: format.height, content: content);
    }
  }
}
