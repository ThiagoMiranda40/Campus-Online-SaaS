# ADR-002 — Isolamento Multi-Tenant por `school_id` e Row Level Security (RLS)

## Status
Aceito (retroativo)   Data: 2026-11-08

## Contexto
**Observado no código:**
- A partir do commit `7d65756`, o sistema deixou de atender uma única escola fixa (*Escola do Empreendedor Raiz*) e passou a ser um SaaS Multi-tenant.
- Foram criadas as tabelas `schools` e `school_members` (`ADMIN`, `TEACHER`, `STUDENT`), e todas as tabelas de conteúdo (`category`, `course`, `module`, `lesson`, `resource`, `course_watchlist`, `diagnostic_*`, `entitlements`) receberam a coluna `school_id`.
- As rotas do aluno foram estruturadas sob `/s/[schoolSlug]/student/*` e as políticas RLS foram configuradas para exigir vínculo em `school_members`.

## Opções consideradas
1. **Banco único compartilhado com coluna `school_id` + Políticas RLS no Postgres (Escolhida)** — Custo zero por nova escola cadastrada, manutenção de um único banco e deploy único; exige disciplina nas políticas RLS e nas constraints `UNIQUE(school_id, ...)`.
2. **Um banco/projeto Supabase separado por escola** — Isolamento físico total, mas inviável financeiramente e operacionalmente (o plano Free do Supabase permite apenas 2 projetos ativos por conta, e cada escola extra custaria US$ 25/mês).

## Decisão
Ratificamos o modelo **Multi-tenant em banco compartilhado com isolamento por `school_id` e RLS obrigatório (`ARQ-01`, `RQ-02`)**, refinando dois pontos (`DT-04` e `DT-05`):
1. Constraints de unicidade de `slug` em `category` e `course` devem ser compostas por escola: `UNIQUE (school_id, slug)`.
2. A tabela `entitlements` também deve ter RLS habilitado.

## Consequências
- **Fica mais fácil:** Criar dezenas de escolas dentro do mesmo projeto Supabase sem pagar nenhum centavo adicional por escola.
- **Fica mais difícil:** Toda nova tabela criada no futuro precisa obrigatoriamente nascer com `school_id` e políticas RLS (`ARQ-01`).

## Em linguagem simples
Todas as escolas dividem o mesmo banco de dados, mas cada curso, categoria e aluno leva o "carimbo" da sua escola (`school_id`), e o próprio banco de dados impede que uma escola veja os dados da outra. Assim você pode cadastrar quantas escolas quiser sem custo extra por escola.

## Revisitar quando
- Uma escola enterprise exigir por contrato banco de dados fisicamente isolado em nuvem dedicada.

