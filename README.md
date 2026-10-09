# Projeto Atlas

Hackathon iPORT 2026: gestão de capacidade das equipes de desenvolvimento a partir do Azure DevOps.

## O que tem aqui

- `central-de-paineis/`: o front (React + TypeScript + Vite). O `index.html` da raiz dele já é o app pronto e abre com duplo clique, mas o login e os dados dependem do n8n rodando.
- `backend/n8n/`: os workflows do n8n (agente IPORT AI, API de capacidade, autenticação e a API mock).
- `backend/sql/`: as tabelas e funções do schema `central` no Supabase, na ordem de rodar.
- `PITCH - Projeto Atlas.md`: o roteiro da apresentação.

## Como rodar

**Front**

```bash
cd central-de-paineis
npm install
cp .env.example .env.local
npm run dev
```

Ele abre em http://localhost:5173. Para gerar o arquivo único de novo, use `npm run build`.

**Backend**

1. Suba o n8n em http://localhost:5678.
2. Crie as credenciais "Postgres account" (o Supabase) e a do Gemini.
3. Importe os 4 JSON de `backend/n8n` e ative os workflows.
4. No Supabase, o banco do time já está montado. Os `.sql` servem para conferência ou para montar de novo: rode em ordem, pelo número.

O schema `public`, com os dados de exemplo, é o do time.

Login admin: 111.111.111-11. A senha o time já tem.
