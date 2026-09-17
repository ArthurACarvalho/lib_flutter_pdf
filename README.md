# lib_pdf

Relatórios PDF escritos com **widgets comuns do Flutter**, com visualizador (zoom, páginas, impressão e salvar) incluído.

```dart
import 'package:flutter/material.dart';
import 'package:lib_pdf/lib_pdf.dart';

final doc = PdfDocument(title: 'Vendas');
doc.addPage(PdfMultiPage(
  header: (ctx) => const Text('Relatório de Vendas', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
  footer: (ctx) => Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}'),
  build: (ctx) => [
    const Card(child: ListTile(title: Text('Total'), trailing: Text('R\$ 65.900'))),
    const PdfKeepTogether(child: SizedBox(height: 240, child: GraficoBarras(dados: vendas))),
    PdfTable(header: TableRow(children: [...]), rows: [...]),
  ],
));
final Uint8List bytes = await doc.save();
```

A geração do PDF é implementada do zero, sem bibliotecas de PDF. O visualizador usa o pacote [`printing`](https://pub.dev/packages/printing) para renderizar as páginas, imprimir e compartilhar.

**Plataformas**: Android e iOS.

Não há sintaxe nova para aprender: `Text`, `Row`, `Column`, `Container`, `Card`, `Table`, `Icon`, `Image`, `CustomPaint`, widgets do app e de pacotes (como `fl_chart`) funcionam como na tela. Só as classes específicas do PDF têm o prefixo `Pdf`.

## Como funciona

1. A árvore de widgets é montada fora da tela e passa pelo layout normal do Flutter, com largura igual à da página.
2. A paginação procura pontos de corte seguros na árvore já calculada.
3. A pintura de cada página passa por um `Canvas` que escreve operadores PDF em vez de pixels.

O resultado é o seguinte:

| Conteúdo | No PDF |
|---|---|
| `Text`, `RichText`, `Text.rich` | Texto real (selecionável e pesquisável), com a fonte embutida em subset |
| Formas, bordas, `CustomPainter`, gráficos (`fl_chart` etc.) | Vetores |
| `BoxDecoration` com `LinearGradient`/`RadialGradient` | Gradiente vetorial |
| `Icon` (MaterialIcons e outras fontes OTF/CFF) | Contornos vetoriais |
| `Image` | Imagem embutida (a mesma imagem repetida em várias páginas é gravada uma só vez) |
| `Opacity`, clips, `Transform` | Nativos do PDF |
| Texto desenhado com `TextPainter` dentro de painters, sombras, `ShaderMask`, `ImageFiltered`, `BackdropFilter` | Imagem em alta resolução, no lugar exato |

O último caso existe porque o Flutter não expõe o conteúdo de um `ui.Paragraph` nem os parâmetros de um `Shader`. Os rótulos de eixo do `fl_chart`, por exemplo, viram pequenas imagens (3× a resolução), enquanto barras, linhas e fatias continuam vetoriais.

## Instalação

```yaml
dependencies:
  lib_pdf:
    git:
      url: https://github.com/ArthurACarvalho/lib_flutter_pdf.git
      ref: main
```

## Documento e páginas

```dart
PdfDocument(
  title: 'Relatório',            // metadados: title, author, subject, keywords, creator
  theme: ThemeData(colorSchemeSeed: Colors.indigo),
  fontFamily: 'Inter',           // opcional; o padrão é a Roboto embutida
  fonts: [PdfFont.asset('fonts/Inter-Regular.ttf', family: 'Inter')],
  locale: const Locale('pt', 'BR'),
  localizationsDelegates: GlobalMaterialLocalizations.delegates, // se usar widgets com textos do Material
  rasterPixelRatio: 3,           // resolução do que precisa virar imagem
  imageTimeout: const Duration(seconds: 10),
  settleDuration: Duration.zero, // > 0 liga as animações e espera antes de capturar
);
```

- **`PdfMultiPage`**: o conteúdo de `build` flui por quantas páginas forem necessárias. Aceita `header`, `footer`, `background`, `foreground`, `format`, `margin`, `theme` e `crossAxisAlignment`.
- **`PdfPage`**: uma página única. `build` recebe exatamente a área interna às margens, como uma tela.
- **`PdfContext`**: chega aos builders (`pageNumber`, `pagesCount`, `format`) e também pode ser lido em qualquer widget com `PdfContext.of(context)`.
- **Formatos**: `PdfPageFormat.a4` (padrão), `a3`, `a5`, `letter`, `legal`, além de `.landscape` e `PdfPageFormat(largura, altura)` em pontos. 1 pixel lógico equivale a 1 ponto; `PdfPageFormat.cm` e `.mm` ajudam nas margens.

## Visualizador

O jeito mais simples é gerar e abrir numa nova tela:

```dart
PdfDocumentViewer.open(context, document: doc, title: 'Relatório de Vendas', fileName: 'vendas.pdf');
```

Para embutir em uma tela sua:

```dart
PdfDocumentViewer.document(doc)          // gera o PDF ao abrir
PdfDocumentViewer.bytes(bytes)           // PDF já gerado (ou qualquer outro PDF)
PdfDocumentViewer(build: () => doc.save())
```

O visual é claro, com duas barras:

- **Barra superior**: nome do arquivo (ou `title`) e os botões imprimir, salvar e fechar. Em tablets e com o celular deitado aparecem também aumentar zoom, diminuir zoom e ajustar à página/largura.
- **Barra inferior**: setas de página anterior e próxima, a caixa "3 / 15" (digite o número e confirme, ou toque fora, para ir à página) e o menu de zoom ("Ajustar à página" e de 25% a 500%).

O que ele oferece:

- **Rolagem contínua** entre as páginas.
- **Zoom** por botões, menu, pinça e toque duplo. 100% é a página ajustada à largura (até 900 px).
- **Impressão** pelo diálogo nativo do sistema.
- **Salvar**: abre o compartilhamento do sistema, que inclui "Salvar em Arquivos", Google Drive, e-mail e WhatsApp.
- **Fechar**: o botão aparece quando há `onClose`. O `open` já passa um que fecha a tela.
- **Nitidez sob demanda**: as páginas aparecem primeiro em baixa resolução e são renderizadas de novo, nítidas, conforme ficam visíveis ou o zoom muda.

Parâmetros úteis:

- `title`, `fileName`, `allowPrinting`, `allowSaving`, `showToolbar` e `backgroundColor`;
- `toolbarActions`, para botões extras. Use `PdfViewerToolbarButton` para manter o estilo.

Com um `PdfDocumentViewerController` dá para montar a própria barra: `zoomIn()`, `zoomOut()`, `fitWidth()`, `fitPage()`, `goToPage(n)`, `nextPage()`, `previousPage()`, `printDocument()`, `saveDocument()`, `reload()`, além de `pageNumber`, `pageCount`, `zoom` e `fitsPage`.

### Configuração

Nada a configurar no Android e no iOS.

## Paginação

O corte entre páginas acontece **apenas** em pontos que não atravessam conteúdo:

- entre filhos de `Column`, `Row`, `Wrap`, `Stack` etc. (em qualquer nível de aninhamento);
- entre linhas de texto de um parágrafo;
- entre linhas de uma `Table`.

Todo o resto é atômico: imagens, `CustomPaint`, widgets rotacionados ou escalados.

Widgets de controle:

- **`PdfKeepTogether(child:)`**: nunca corta o filho. Se ele não couber, começa na próxima página. Use em gráficos, cards e blocos de assinatura.
- **`PdfPageBreak()`**: força uma nova página e funciona em qualquer nível da árvore.
- **`PdfTable(header:, rows:, ...)`**: uma `Table` do Flutter que repete o cabeçalho no topo de cada página de continuação. Aceita os mesmos parâmetros de `Table` (`columnWidths`, `border` etc.).
- **`PdfRasterize(child:)`**: força uma subárvore a virar imagem.

Se um bloco sem pontos de corte for maior que a página inteira, ele é cortado na altura da página e um aviso é emitido no console.

## Gráficos

Qualquer widget de gráfico serve. Duas recomendações:

- **Desligue as animações de entrada**: `duration: Duration.zero` no `fl_chart`, `animationDuration: 0` no Syncfusion. Sem isso, a captura mostra o primeiro quadro da animação. Outra saída é usar `settleDuration`.
- **Dê altura definida**: por exemplo `SizedBox(height: 240, child: ...)`, porque o conteúdo de um `PdfMultiPage` tem altura livre, como dentro de uma `ListView`.

## Fontes

- **Sem configuração**, os textos usam a **Roboto** embutida na lib, que cobre todos os acentos do português.
- **Fontes declaradas no `pubspec.yaml` do app** (inclusive de pacotes) são procuradas no `FontManifest` quando um `TextStyle` usa `fontFamily`. Esse caminho ainda não tem teste automatizado; na dúvida, registre a fonte com `PdfFont`.
- **Fontes fora do bundle** são registradas com `PdfFont.memory(bytes, family:)` ou `PdfFont.asset(key, family:)`.

Formatos suportados: TrueType (`.ttf`) vira texto real, e OpenType/CFF (`.otf`) vira contornos. Coleções `.ttc` não são suportadas. Se um texto usa uma família cujo arquivo não é encontrado (por exemplo, uma fonte do sistema), aquele parágrafo vira imagem.

## Imagens

`Image.memory` é coberto pelos testes; `Image.asset`, `Image.file` e `Image.network` usam o mesmo caminho (`RawImage`), e o `save()` espera as imagens carregarem por até `imageTimeout`. Os pixels são gravados sem perdas (Flate): para relatórios com muitas fotos grandes, reduza as imagens antes de usá-las.

## Testes

Em `testWidgets`, gere o PDF dentro de `tester.runAsync`, porque a captura de imagens é assíncrona de verdade:

```dart
testWidgets('relatório', (tester) async {
  final bytes = (await tester.runAsync(doc.save))!;
  expect(bytes, isNotEmpty);
});
```

Nos testes, o `flutter_test` desenha sombras de `Material` como contornos (`debugDisableShadows`). Fontes do app, como `MaterialIcons`, precisam ser carregadas com `FontLoader`.

Os testes do pacote validam os PDFs com `qpdf`/`poppler` quando estão disponíveis. Por padrão eles são procurados no `PATH`; também dá para apontar a variável `LIB_PDF_TOOLS` para um script que exporte `PATH`/`LD_LIBRARY_PATH`. Para pular o teste de desempenho, use `flutter test --exclude-tags perf`. Para testar telas com o visualizador, passe um `PdfViewerBackend` falso em `backend:` (veja `test/viewer_test.dart`).

## Limitações conhecidas

- **Direção do texto**: texto RTL vira imagem. Scripts com shaping complexo (árabe, devanágari) não são suportados como texto real: com a Roboto padrão eles viram imagem, mas com uma fonte que tenha esses glifos sairiam sem shaping.
- **Ligaduras e kerning**: são aproximados. Cada palavra é posicionada exatamente onde o Flutter a colocou, mas as letras internas usam as larguras da fonte ajustadas à largura da palavra.
- **Execução**: a geração roda na thread principal (ela depende do motor de layout do Flutter). Como referência, uma tabela de 2.000 linhas (cerca de 50 páginas) leva de 1,5 a 2,5 s num computador; em celulares, conte com mais tempo.
- **`GlobalKey`s**: são compartilhadas com o app, então não reutilize a mesma chave na tela e no relatório ao mesmo tempo.
- **Aparelhos reais**: o visualizador foi validado em testes automatizados. Impressão e compartilhamento ainda não foram testados em aparelhos.

## Exemplo

`example/` tem um app com um relatório de vendas completo: indicadores, gráfico `CustomPainter`, gráficos de linha e pizza do `fl_chart`, tabela de 120 linhas paginada e quebra de página.

```sh
cd example
flutter test          # gera build/relatorio_vendas.pdf
flutter run           # botão "Abrir relatório" abre o visualizador
```
