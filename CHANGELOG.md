## 0.1.0

Primeira versão.

- Geração de PDF a partir de widgets comuns do Flutter, implementada do zero: texto real com fontes embutidas em subset, formas e gráficos vetoriais, gradientes, ícones como contornos e imagens.
- Fallback para imagem no que o Flutter não expõe (texto de `TextPainter` em painters, sombras, shaders e filtros).
- Paginação automática com `PdfMultiPage`, cabeçalho, rodapé e "Página X de Y", além de `PdfPage`, `PdfKeepTogether`, `PdfPageBreak`, `PdfTable` (cabeçalho repetido) e `PdfRasterize`.
- Fonte Roboto embutida, fontes do app via `FontManifest` e registro com `PdfFont`.
- `PdfDocumentViewer` para Android e iOS: rolagem contínua, navegação por página, zoom (botões, menu, pinça e toque duplo), ajustar à página, impressão e compartilhamento.
