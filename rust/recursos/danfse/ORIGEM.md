Os domínios, textos, logo e posições foram extraídos da BrazilFiscalReport
instalada durante a migração, que já contém as adaptações usadas pelo sistema
Python para o layout v2.0. Fonte: https://github.com/Engenere/BrazilFiscalReport
(LGPL-3.0). As métricas Helvetica seguem fpdf2 (LGPL-3.0).
Segmentação e pontuação de QR seguem python-qrcode (BSD-3-Clause),
https://github.com/lincolnloop/python-qrcode. Codificação em Rust: crate qrcode.

O gerador de referência em `emissor/verificacao/extrair_referencia_danfse.py`
é usado apenas durante o desenvolvimento. Os recursos e o gerador Rust são
incluídos no binário: nenhum processo Python é executado pelo aplicativo.

O código de desenho derivado deve acompanhar a licença LGPL-3.0 e seu fonte
correspondente na distribuição. Alterações locais estão em `src/danfse.rs`,
`src/danfse_dados.rs` e `src/pdf.rs`.
