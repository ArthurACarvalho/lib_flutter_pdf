# Exemplo da lib_pdf

App com um relatório de vendas completo, escrito com widgets do Flutter:

- indicadores em `Card`;
- gráfico de barras com `CustomPainter`;
- gráficos de linha e de pizza do `fl_chart`;
- tabela de 120 linhas paginada, com cabeçalho repetido;
- quebra de página e rodapé "Página X de Y".

O relatório fica em [`lib/relatorio_vendas.dart`](lib/relatorio_vendas.dart) e o botão que abre o visualizador, em [`lib/main.dart`](lib/main.dart).

```sh
flutter test   # gera build/relatorio_vendas.pdf
flutter run    # abre o app (Android ou iOS)
```
