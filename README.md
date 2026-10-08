# Capacidade do time

App do Hackaton iPORT: usa os dados do Azure DevOps (sem substituí-lo) para mostrar a capacidade do time e ajudar o gestor a decidir alocações antes de virar problema.

| Requisito do desafio | Onde está |
| --- | --- |
| 1. Sincronizar projetos, work items, iterações e capacidade | `src/lib/sources/azure-devops.ts`, rota `GET /api/snapshot`, botão **Sincronizar** |
| 2. Entender pessoas: capacidade semanal, ausências, calendário | `Person.capacityPerDay`, `daysOff` e feriados/folgas do time, em `src/lib/capacity.ts` |
| 3. Timeline por pessoa, atividade e período | `src/components/Timeline.tsx` (8 semanas a partir da atual) |
| 4. Realocar com drag-and-drop | Arraste um item para outra pessoa/semana; as mudanças são uma simulação local (botão **Desfazer**) |
| 5. Heatmap de utilização e sobrecarga | `src/components/Heatmap.tsx` |
| 6. Alertas de conflitos, ausências, feriados e sobreposição | `computeAlerts` em `src/lib/capacity.ts`, painel `src/components/AlertsPanel.tsx` |

## Rodando localmente

Requer Node.js 20.9 ou mais novo.

```bash
npm install
npm run dev
```

Abra http://localhost:3000. Sem configuração, o app roda com **dados de demonstração** (um time fictício de 5 pessoas, com datas relativas à semana atual).

### Conectando ao Azure DevOps

1. Crie um Personal Access Token em `https://dev.azure.com/<org>/_usersSettings/tokens` com os escopos **Work Items (Read)** e **Project and Team (Read)**.
2. Copie `.env.example` para `.env.local` e preencha:

   ```bash
   AZDO_ORG=minha-org
   AZDO_PROJECT=MeuProjeto
   AZDO_TEAM="MeuProjeto Team"   # opcional, padrão "<projeto> Team"
   AZDO_PAT=xxxxxxxx
   ```

3. Reinicie o `npm run dev`. O cabeçalho passa a mostrar "Fonte: Azure DevOps".

O que é lido: iterações do time, capacidade por pessoa (soma das atividades por dia) e dias de folga em cada iteração, folgas do time (tratadas como feriados) e work items abertos (User Story, PBI, Task, Bug). Cada item usa `Start Date`/`Target Date`; sem elas, as datas da iteração. O esforço é `Remaining Work` (ou `Original Estimate`), distribuído igualmente pelos dias úteis do item.

## Como funciona

```
Azure DevOps ──► /api/snapshot ──► Snapshot (JSON) ──► computeLoad / computeAlerts ──► Heatmap, Timeline, Alertas
 (ou demo)        (servidor, PAT)                       (no navegador, recalcula a cada realocação)
```

- **Capacidade da semana** = horas por dia × dias úteis da pessoa (sem fins de semana, feriados e ausências).
- **Carga da semana** = soma das horas dos itens que caem naquela semana.
- **Utilização** = carga ÷ capacidade. Acima de 85% vira aviso, acima de 100% vira sobrecarga.
- O PAT fica só no servidor; o navegador nunca o vê.

## Estrutura

```
src/
  app/
    page.tsx                 página única
    api/snapshot/route.ts    sincronização (Azure DevOps ou demo)
  components/                Dashboard, Heatmap, Timeline (dnd-kit), AlertsPanel
  lib/
    types.ts                 modelo de dados
    capacity.ts              carga, utilização, alertas e realocação
    data.ts                  escolhe a fonte de dados
    sources/                 azure-devops.ts e demo.ts
```

## Stack

Next.js 16 (App Router) com TypeScript, Tailwind CSS 4, `@dnd-kit/core` para o drag-and-drop e `date-fns` para datas.

## Scripts

- `npm run dev`: servidor de desenvolvimento
- `npm run build` e `npm start`: build e servidor de produção
- `npm run lint`: ESLint

## Próximos passos

- Gravar a realocação de volta no Azure DevOps (PATCH em `System.AssignedTo` e datas) após confirmação do gestor.
- Sugestões com IA: propor para quem mover um item sobrecarregado e explicar o porquê.
- Persistir ausências e feriados extras cadastrados no app.
- Filtros por projeto, tipo de item e iteração.
