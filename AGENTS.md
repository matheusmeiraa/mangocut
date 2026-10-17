# Regras para quem contribui (pessoas e agentes)

## Clean-room

Daqui para frente, todo código novo do MangoCUT segue estas regras:

1. **Só comportamento e aparência.** O CapCut e outros editores podem ser estudados usando o app: criando
   projetos, exportando vídeos e observando o resultado. O binário deles não é estudado.
2. **Nada copiado.** Não entra código, shader, LUT, preset, efeito, filtro, fonte, sticker, música, ícone
   ou template de outro produto, nem quando estiver legível.
3. **Fontes permitidas:** especificações públicas (ISO/IEC 14496 para MP4, documentação da Apple),
   artigos acadêmicos, arquivos de projeto que os próprios usuários criaram e o que se observa usando
   os apps.
4. **Material de engenharia reversa fica de fora.** A pasta `app/` e as notas `achados.md`,
   `inventario.md` e `RELATORIO.md` (que existem só na máquina do autor e estão no `.gitignore`) não
   podem ser consultadas para escrever código novo.
5. **Assets próprios ou de licença livre.** Todo asset novo é criado por nós ou tem licença
   permissiva. Os textos usam as fontes do sistema, que não vêm no app.

O motor de leitura e reparo de drafts (`src/draft.ts`, `src/time.ts` e `src/bezier.ts`) veio de uma fase
anterior de engenharia reversa. Por isso, o projeto como um todo não se apresenta como clean-room.

## Arquitetura

- **Motor primeiro.** Toda edição é um comando em `src/editor.ts`, com id, parâmetros validados e
  testes. A CLI (`mangocut run`) e o app iOS chamam os mesmos comandos.
- **Plano de render.** `buildRenderPlan` converte o draft numa lista ordenada de clipes, transições e
  textos. O app só lê esse plano para tocar e exportar o vídeo.
- **Draft compatível.** Cortes, ordem e velocidade ficam nas trilhas e segmentos padrão. Filtros,
  efeitos, transições e textos do MangoCUT ficam no bloco `mangocut` do draft.

## Testes

- `npm test` roda os testes do motor e da CLI e precisa passar.
- Mudanças no app iOS precisam compilar no CI (`.github/workflows/build-ipa.yml`). Mudanças visíveis
  precisam ser conferidas nos screenshots do simulador, publicados na branch `ci-screenshots`.
