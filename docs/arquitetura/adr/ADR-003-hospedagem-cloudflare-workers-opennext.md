# ADR-003 — Hospedagem na Cloudflare Workers via `@opennextjs/cloudflare` e GitHub

## Status
Proposto   Data: 2026-11-08

## Contexto
O dono do produto deseja publicar a aplicação **Campus Online SaaS** na **Cloudflare Workers** conectada diretamente ao repositório do **GitHub**.

Analisando a stack real do projeto (`package.json`, `middleware.ts`, `app/`), verificamos que:
1. O projeto usa **Next.js 15.1.7 (App Router)** com rotas dinâmicas (`/s/[schoolSlug]/*`, `/teacher/courses/[id]`), Route Handler (`app/auth/callback/route.ts`) e Middleware (`middleware.ts`).
2. Não há nenhuma dependência de bibliotecas nativas do Node.js/C++ ou escrita em disco local: toda comunicação externa usa `fetch` padrão Web (`@supabase/ssr`, `@supabase/supabase-js`) e os uploads vão direto do navegador para o Supabase Storage.
3. A Cloudflare e a comunidade OpenNext substituíram o antigo `@cloudflare/next-on-pages` pelo adaptador oficial **`@opennextjs/cloudflare`**, que suporta oficialmente o Next.js 15 App Router rodando sobre o runtime da Cloudflare Workers com a flag `nodejs_compat`.
4. Além disso, a Cloudflare Workers oferece integração nativa com o GitHub (**Workers Builds**) e suporte gratuito a **Cron Triggers**, permitindo resolver também o requisito `RQ-01` (impedir que o Supabase gratuito pause por inatividade).

## Opções consideradas
1. **Cloudflare Workers com `@opennextjs/cloudflare` + Integração GitHub (Proposta)** — Rede de borda global ultra-rápida no Brasil (`RQ-03`), plano gratuito generoso (100.000 reqs SSR/dia + assets estáticos ilimitados), Cron Trigger nativo para manter o Supabase acordado (`RQ-01`), e plano pago de apenas US$ 5/mês quando crescer (`EV-02`).
2. **Vercel (Hobby / Pro)** — Integração zero-config com Next.js, porém o plano gratuito (Hobby) possui restrições comerciais para SaaS nos Termos de Uso, não inclui Cron com frequência menor que 1x/dia sem limites estritos, e o salto para o plano Pro custa US$ 20/usuário/mês.
3. **VPS / Docker (Railway, Render, Fly.io)** — Maior controle do runtime Node.js, mas gera custo fixo mensal imediato (US$ 5 a US$ 20/mês) mesmo sem tráfego.

## Decisão
Adotar a **Cloudflare Workers** utilizando o adaptador **`@opennextjs/cloudflare`** (`wrangler.jsonc` com `nodejs_compat` e Workers Assets), integrado diretamente à branch `main` do GitHub via **Cloudflare Workers Builds** (ou GitHub Actions).

## Consequências
- **Fica mais fácil:** Deploy automático a cada `git push origin main`; custo inicial zero; latência mínima em todo o Brasil; possibilidade de agendar um Cron Trigger gratuito na própria Cloudflare para manter o Supabase ativo (`EV-01`).
- **Fica mais difícil:** Exige manter o projeto livre de pacotes Node.js que dependam de binários C++ nativos em tempo de execução e manter a tipagem TypeScript limpa (`ARQ-04` / `DT-01`), pois o build do OpenNext valida o projeto inteiro antes de gerar `.open-next/worker.js`.

## Em linguagem simples
Vamos hospedar o Campus Online na Cloudflare Workers ligada ao seu GitHub: toda vez que você salvar código novo no GitHub, a Cloudflare atualiza o site sozinha, sem custo mensal inicial e com carregamento rápido no Brasil inteiro.

## Revisitar quando
- O tamanho compactado do Worker ultrapassar 3 MB ou o tráfego passar de 70.000 acessos dinâmicos/dia → acionar `EV-02` (subir para Cloudflare Workers Paid por US$ 5/mês).

