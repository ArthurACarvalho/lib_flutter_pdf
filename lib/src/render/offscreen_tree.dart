import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Árvore de widgets montada fora da tela, com seu próprio [BuildOwner] e
/// [PipelineOwner], usada para medir e pintar o conteúdo das páginas.
class OffscreenTree {
  OffscreenTree({required BoxConstraints constraints}) {
    final dispatcher = ui.PlatformDispatcher.instance;
    final view = dispatcher.implicitView ?? dispatcher.views.first;
    _renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        logicalConstraints: constraints,
        physicalConstraints: constraints,
        devicePixelRatio: 1,
      ),
    );
    _pipelineOwner = PipelineOwner()..rootNode = _renderView;
    _renderView.prepareInitialFrame();
    // O BuildOwner do app é compartilhado porque `GlobalKey.currentContext`
    // só consulta o registro dele; o RootElement desta árvore tem seu próprio
    // BuildScope, então os rebuilds continuam isolados.
    _buildOwner = WidgetsBinding.instance.buildOwner!;
  }

  late final RenderView _renderView;
  late final PipelineOwner _pipelineOwner;
  late final BuildOwner _buildOwner;
  RenderObjectToWidgetElement<RenderBox>? _root;
  bool _disposed = false;

  /// Raiz do conteúdo (filho do [RenderView]).
  RenderBox? get root => _renderView.child;

  Size get size => _renderView.size;

  /// Monta (ou atualiza) a árvore com [widget] e faz o layout.
  void setWidget(Widget widget) {
    assert(!_disposed);
    _root = RenderObjectToWidgetAdapter<RenderBox>(
      container: _renderView,
      child: widget,
    ).attachToRenderTree(_buildOwner, _root);
    flush();
  }

  void flush() {
    final root = _root;
    if (root == null) return;
    _buildOwner
      ..buildScope(root)
      ..finalizeTree();
    _pipelineOwner
      ..flushLayout()
      ..flushCompositingBits();
  }

  /// Aguarda imagens carregarem (e animações, se [settle] > 0), refazendo o
  /// build e o layout a cada ciclo.
  Future<void> settle({required Duration imageTimeout, Duration settle = Duration.zero}) async {
    final start = DateTime.now();
    while (_hasPendingImages() && DateTime.now().difference(start) < imageTimeout) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      flush();
    }
    if (settle > Duration.zero) {
      final end = DateTime.now().add(settle);
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        flush();
      }
    }
    flush();
  }

  bool _hasPendingImages() {
    var pending = false;
    void visit(Element element) {
      if (pending) return;
      final renderObject = element.renderObject;
      if (element.widget is RawImage && renderObject is RenderImage && renderObject.image == null) {
        pending = true;
        return;
      }
      element.visitChildren(visit);
    }

    _root?.visitChildren(visit);
    return pending;
  }

  /// Famílias de fonte usadas pelos textos da árvore.
  Set<String> collectFontFamilies() {
    final families = <String>{};
    void visit(RenderObject node) {
      if (node is RenderParagraph) {
        void span(InlineSpan s, TextStyle? inherited) {
          final style = inherited == null ? s.style : inherited.merge(s.style);
          final family = style?.fontFamily;
          if (family != null) families.add(family);
          if (s is TextSpan) {
            for (final child in s.children ?? const <InlineSpan>[]) {
              span(child, style);
            }
          }
        }

        span(node.text, null);
      }
      node.visitChildren(visit);
    }

    final r = root;
    if (r != null) visit(r);
    return families;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final root = _root;
    if (root != null) {
      // Desmonta a árvore para liberar States, controllers e listeners.
      RenderObjectToWidgetAdapter<RenderBox>(container: _renderView).attachToRenderTree(_buildOwner, root);
      _buildOwner
        ..buildScope(root)
        ..finalizeTree();
    }
    _pipelineOwner
      ..rootNode = null
      ..dispose();
  }
}
