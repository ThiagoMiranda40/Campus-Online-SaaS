# ADR-001 — Stack Principal em Next.js 15 (App Router) com Supabase BaaS

## Status
Aceito (retroativo)   Data: 2026-11-08

## Contexto
**Observado no código:**
- O projeto foi construído em Next.js (`^15.1.7`) utilizando o App Router (`app/`), React 19, TypeScript e Tailwind CSS.
- Toda a persistência de dados (PostgreSQL), autenticação (`auth.users`) e armazenamento de arquivos (`storage.buckets`: `course-thumbnails`, `lesson-resources`, `avatars`) utilizam diretamente o Supabase via `@supabase/ssr` (`^0.8.0`) e `@supabase/supabase-js` (`^2.95.3`), sem servidor intermediário próprio.
- Motivo original: não registrado formalmente em ADR na época do commit inicial (`62e44e6`), mas evidente pela busca de velocidade de entrega de MVP e custo zero de infraestrutura inicial.

**Confirmado pelo dono do produto:**
- O projeto operava no plano gratuito (Free Tier) do Supabase, o qual foi pausado/removido por inatividade, exigindo recriação do banco do zero e estratégia para evitar nova pausa involuntária (`RQ-01`).

## Opções consideradas
1. **Next.js (Frontend/SSR) + Supabase BaaS direto (Escolhida no código)** — Desenvolvimento rápido, autenticação e upload de arquivos prontos, custo mensal R$ 0 no início; exige rigor em Row Level Security (RLS) no banco e estratégia de *keep-alive* no plano gratuito.
2. **Next.js + Backend próprio (Node/NestJS + Prisma) + Postgres avulso** — Maior desacoplamento do banco, porém exige hospedar e manter um segundo servidor de API, escrever autenticação e upload do zero e aumenta o custo e tempo de manutenção.

## Decisão
Ratificamos a stack **Next.js 15 (App Router) + Supabase (Auth, Postgres, Storage)** acessada via `@supabase/ssr`, adicionando duas exigências operacionais:
1. Todo o schema, triggers de `auth.users` e políticas RLS devem estar consolidados e versionados na pasta `supabase/` do repositório (`DT-02`, `DT-03`).
2. Enquanto o projeto operar no plano gratuito do Supabase, um *heartbeat* automático a cada 72 horas (`EV-01` / `RQ-01`) manterá o banco ativo.

## Consequências
- **Fica mais fácil:** Subir um novo ambiente do zero em minutos; operar sem custo fixo mensal; fazer upload de imagens e PDFs direto do navegador para o Storage sem sobrecarregar o servidor Next.js.
- **Fica mais difícil:** Qualquer esquecimento de política RLS numa tabela expõe dados (`ARQ-01`); trocar o Supabase no futuro exigirá refatorar as chamadas `supabase.from(...)` presentes nas páginas (`EV-04`).

## Em linguagem simples
Mantemos o sistema rodando direto sobre o Supabase porque ele entrega banco de dados, login e armazenamento de arquivos prontos e de graça no início. Para evitar que o Supabase gratuito desligue sozinho por falta de uso, deixaremos um aviso automático batendo nele a cada 3 dias.

## Revisitar quando
- O banco atingir 70% do limite gratuito (350 MB) → acionar `EV-03` (migrar para Supabase Pro).
- O número de telas com consultas repetidas passar de 30 → acionar `EV-04` (extrair camada de serviços).

