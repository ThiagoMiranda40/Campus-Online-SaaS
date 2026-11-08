-- =============================================================================
-- CAMPUS ONLINE SAAS — BOOTSTRAP COMPLETO DO BANCO DE DADOS (SUPABASE)
-- =============================================================================
-- Como usar:
-- 1. Crie um novo projeto no Supabase (https://database.new).
-- 2. Abra o "SQL Editor" no painel do Supabase.
-- 3. Cole TODO o conteúdo deste arquivo e clique em "Run".
-- 
-- Este script consolida o schema base + todas as 19 migrations + correções da
-- auditoria arquitetural (DT-02, DT-03, DT-04, DT-05) de forma 100% idempotente.
-- =============================================================================

-- 0. Extensões necessárias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- 1. TABELAS MULTI-TENANT E PERFIS DE USUÁRIO
-- =============================================================================

-- 1.1 Escolas (Tenants)
CREATE TABLE IF NOT EXISTS public.schools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 1.2 Perfil de Usuários (sincronizado com auth.users via Trigger — DT-02)
CREATE TABLE IF NOT EXISTS public.users_profile (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT,
  role TEXT CHECK (role IN ('STUDENT', 'TEACHER', 'MANAGER', 'ADMIN')) DEFAULT 'STUDENT',
  payment_status TEXT DEFAULT 'active',
  avatar_url TEXT,
  bio TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 1.3 Membros por Escola (Papel do usuário dentro de cada escola)
CREATE TABLE IF NOT EXISTS public.school_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('ADMIN', 'TEACHER', 'STUDENT')),
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(school_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_school_members_user_school ON public.school_members(user_id, school_id);

-- 1.4 Trigger automático para popular users_profile no Signup (Correção DT-02)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users_profile (id, name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'role', 'STUDENT')
  )
  ON CONFLICT (id) DO UPDATE
  SET
    name = COALESCE(EXCLUDED.name, public.users_profile.name),
    role = COALESCE(EXCLUDED.role, public.users_profile.role),
    updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================================================
-- 2. TABELAS DE CONTEÚDO (CATEGORIAS, CURSOS, MÓDULOS, AULAS, MATERIAIS)
-- =============================================================================

-- 2.1 Categorias (inclui description [DT-03] e slug único por escola [DT-04])
CREATE TABLE IF NOT EXISTS public.category (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  description TEXT,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (school_id, slug)
);

CREATE INDEX IF NOT EXISTS idx_category_school_id ON public.category(school_id);

-- 2.2 Cursos (inclui capas horizontal/vertical, modelo de acesso e tiers)
CREATE TABLE IF NOT EXISTS public.course (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  category_id UUID NOT NULL REFERENCES public.category(id) ON DELETE CASCADE,
  teacher_id UUID NOT NULL REFERENCES public.users_profile(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  slug TEXT,
  description TEXT,
  thumb_url TEXT,
  thumb_vertical_url TEXT,
  status TEXT CHECK (status IN ('draft', 'published')) DEFAULT 'draft',
  access_model TEXT NOT NULL DEFAULT 'OPEN',
  course_tier TEXT NOT NULL DEFAULT 'TIER_1',
  required_entitlement_key TEXT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (school_id, slug),
  CONSTRAINT course_access_model_check CHECK (access_model IN ('OPEN', 'ENTITLEMENT_REQUIRED')),
  CONSTRAINT course_tier_check CHECK (course_tier IN ('TIER_1', 'TIER_2', 'TIER_3', 'TIER_4', 'TIER_5')),
  CONSTRAINT course_required_entitlement_key_format CHECK (required_entitlement_key IS NULL OR length(trim(required_entitlement_key)) > 0),
  CONSTRAINT course_entitlement_key_required_logic CHECK (
    (access_model = 'OPEN')
    OR
    (access_model = 'ENTITLEMENT_REQUIRED' AND required_entitlement_key IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_course_teacher_id ON public.course(teacher_id);
CREATE INDEX IF NOT EXISTS idx_course_category_id ON public.course(category_id);
CREATE INDEX IF NOT EXISTS idx_course_school_id ON public.course(school_id);
CREATE INDEX IF NOT EXISTS idx_course_school_status ON public.course(school_id, status);
CREATE INDEX IF NOT EXISTS idx_course_school_access ON public.course(school_id, access_model);

-- 2.3 Trigger de proteção: apenas ADMIN da escola altera modelo de acesso/tier do curso
CREATE OR REPLACE FUNCTION public.check_course_access_update_permission()
RETURNS TRIGGER AS $$
DECLARE
    v_user_role TEXT;
BEGIN
    IF (TG_OP = 'UPDATE' AND (
        OLD.access_model IS DISTINCT FROM NEW.access_model OR
        OLD.course_tier IS DISTINCT FROM NEW.course_tier OR
        OLD.required_entitlement_key IS DISTINCT FROM NEW.required_entitlement_key
    )) OR (TG_OP = 'INSERT' AND (
        NEW.access_model IS DISTINCT FROM 'OPEN' OR
        NEW.course_tier IS DISTINCT FROM 'TIER_1' OR
        NEW.required_entitlement_key IS NOT NULL
    )) THEN
        -- Permite se for execução via SQL Editor (service_role / postgres sem auth.uid())
        IF auth.uid() IS NULL THEN
            RETURN NEW;
        END IF;

        SELECT role INTO v_user_role
        FROM public.school_members
        WHERE school_id = NEW.school_id 
        AND user_id = auth.uid();

        IF v_user_role IS DISTINCT FROM 'ADMIN' THEN
            RAISE EXCEPTION 'Apenas administradores da escola podem alterar o modelo de acesso ou tier do curso.';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS tr_enforce_course_admin_only_fields ON public.course;
CREATE TRIGGER tr_enforce_course_admin_only_fields
BEFORE UPDATE ON public.course
FOR EACH ROW EXECUTE FUNCTION public.check_course_access_update_permission();

DROP TRIGGER IF EXISTS tr_enforce_course_admin_only_fields_insert ON public.course;
CREATE TRIGGER tr_enforce_course_admin_only_fields_insert
BEFORE INSERT ON public.course
FOR EACH ROW EXECUTE FUNCTION public.check_course_access_update_permission();

-- 2.4 Módulos
CREATE TABLE IF NOT EXISTS public.module (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  course_id UUID NOT NULL REFERENCES public.course(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  order_index INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_module_course_id ON public.module(course_id);
CREATE INDEX IF NOT EXISTS idx_module_school_id ON public.module(school_id);

-- 2.5 Aulas
CREATE TABLE IF NOT EXISTS public.lesson (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  course_id UUID NOT NULL REFERENCES public.course(id) ON DELETE CASCADE,
  module_id UUID NOT NULL REFERENCES public.module(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  video_url TEXT,
  panda_embed TEXT,
  order_index INT DEFAULT 0,
  status TEXT CHECK (status IN ('draft', 'published')) DEFAULT 'draft',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lesson_module_id ON public.lesson(module_id);
CREATE INDEX IF NOT EXISTS idx_lesson_course_id ON public.lesson(course_id);
CREATE INDEX IF NOT EXISTS idx_lesson_school_id ON public.lesson(school_id);

-- 2.6 Materiais Complementares (Resources)
CREATE TABLE IF NOT EXISTS public.resource (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  lesson_id UUID NOT NULL REFERENCES public.lesson(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  url TEXT,
  file_path TEXT,
  type TEXT DEFAULT 'LINK' CHECK (type IN ('LINK', 'FILE', 'link', 'file')),
  order_index INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_resource_lesson_id ON public.resource(lesson_id);
CREATE INDEX IF NOT EXISTS idx_resource_school_id ON public.resource(school_id);

-- 2.7 View de Estatísticas do Curso
CREATE OR REPLACE VIEW public.course_stats AS
SELECT 
    c.id AS course_id,
    COUNT(DISTINCT m.id) AS module_count,
    COUNT(DISTINCT l.id) FILTER (WHERE l.status = 'published') AS published_lesson_count
FROM 
    public.course c
LEFT JOIN 
    public.module m ON c.id = m.course_id
LEFT JOIN 
    public.lesson l ON c.id = l.course_id
GROUP BY 
    c.id;

GRANT SELECT ON public.course_stats TO authenticated;
GRANT SELECT ON public.course_stats TO service_role;

-- =============================================================================
-- 3. TABELAS DE ACESSO COMERCIAL E EXPERIÊNCIA DO ALUNO
-- =============================================================================

-- 3.1 Entitlements (Permissões / Assinaturas / Compras Avulsas)
CREATE TABLE IF NOT EXISTS public.entitlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    key TEXT NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ends_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    source TEXT NOT NULL DEFAULT 'MANUAL',
    provider TEXT NOT NULL DEFAULT 'NONE',
    provider_customer_id TEXT,
    provider_subscription_id TEXT,
    provider_order_id TEXT,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT entitlements_status_check CHECK (status IN ('ACTIVE','CANCELED','EXPIRED')),
    CONSTRAINT entitlements_key_check CHECK (length(trim(key)) > 0),
    CONSTRAINT entitlements_provider_check CHECK (provider IN ('NONE','ASAAS','HOTMART','EDUZZ','MONETIZZE','VOOMP','STRIPE','MANUAL')),
    CONSTRAINT entitlements_source_check CHECK (source IN ('MANUAL','IMPORT','WEBHOOK'))
);

CREATE INDEX IF NOT EXISTS idx_entitlements_school_user ON public.entitlements (school_id, user_id);
CREATE INDEX IF NOT EXISTS idx_entitlements_school_key ON public.entitlements (school_id, key);
CREATE INDEX IF NOT EXISTS idx_entitlements_provider_order ON public.entitlements (provider, provider_order_id) WHERE provider_order_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS unique_active_entitlement ON public.entitlements (school_id, user_id, key) WHERE (status = 'ACTIVE');

-- 3.2 Watchlist ("Minha Lista" do Aluno)
CREATE TABLE IF NOT EXISTS public.course_watchlist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  course_id UUID NOT NULL REFERENCES public.course(id) ON DELETE CASCADE,
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, course_id)
);

-- 3.3 Diagnóstico de Onboarding do Aluno (Trilha Personalizada)
CREATE TABLE IF NOT EXISTS public.diagnostic_questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  description TEXT,
  "order" INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.diagnostic_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID NOT NULL REFERENCES public.diagnostic_questions(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  icon TEXT,
  weight INTEGER DEFAULT 1,
  mapped_categories JSONB DEFAULT '[]'::jsonb,
  "order" INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.user_diagnostic_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  school_id UUID NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  top_categories JSONB DEFAULT '[]'::jsonb,
  onboarding_completed BOOLEAN DEFAULT false,
  last_completed_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, school_id)
);

-- =============================================================================
-- 4. ROW LEVEL SECURITY (RLS) — ISOLAMENTO MULTI-TENANT (ARQ-01)
-- =============================================================================

ALTER TABLE public.schools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.users_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.school_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.category ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.module ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lesson ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resource ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entitlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_watchlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diagnostic_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diagnostic_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_diagnostic_results ENABLE ROW LEVEL SECURITY;

-- 4.1 Policies: schools
DROP POLICY IF EXISTS "View schools membership" ON public.schools;
CREATE POLICY "View schools membership" ON public.schools
  FOR SELECT USING (true);

-- 4.2 Policies: users_profile (inclui INSERT para permitir upsert — DT-02)
DROP POLICY IF EXISTS "Users can select their own profile" ON public.users_profile;
CREATE POLICY "Users can select their own profile" ON public.users_profile
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can insert their own profile" ON public.users_profile;
CREATE POLICY "Users can insert their own profile" ON public.users_profile
  FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update their own profile" ON public.users_profile;
CREATE POLICY "Users can update their own profile" ON public.users_profile
  FOR UPDATE USING (auth.uid() = id);

-- 4.3 Policies: school_members
DROP POLICY IF EXISTS "Users view own membership" ON public.school_members;
CREATE POLICY "Users view own membership" ON public.school_members
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Allow members to join school" ON public.school_members;
CREATE POLICY "Allow members to join school" ON public.school_members
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 4.4 Policies: category
DROP POLICY IF EXISTS "Select category school members" ON public.category;
CREATE POLICY "Select category school members" ON public.category
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = category.school_id AND sm.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Manage category school teachers" ON public.category;
CREATE POLICY "Manage category school teachers" ON public.category
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = category.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = category.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  );

-- 4.5 Policies: course
DROP POLICY IF EXISTS "Select course school members" ON public.course;
CREATE POLICY "Select course school members" ON public.course
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.school_members sm 
      WHERE sm.school_id = course.school_id 
      AND sm.user_id = auth.uid() 
      AND (sm.role IN ('TEACHER', 'ADMIN') OR course.status = 'published')
    )
  );

DROP POLICY IF EXISTS "Manage course school teachers" ON public.course;
CREATE POLICY "Manage course school teachers" ON public.course
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = course.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = course.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  );

-- 4.6 Policies: module
DROP POLICY IF EXISTS "Select module school members" ON public.module;
CREATE POLICY "Select module school members" ON public.module
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = module.school_id AND sm.user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Manage module school teachers" ON public.module;
CREATE POLICY "Manage module school teachers" ON public.module
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = module.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = module.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  );

-- 4.7 Policies: lesson
DROP POLICY IF EXISTS "Select lesson school members" ON public.lesson;
CREATE POLICY "Select lesson school members" ON public.lesson
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.school_members sm 
      WHERE sm.school_id = lesson.school_id 
      AND sm.user_id = auth.uid() 
      AND (sm.role IN ('TEACHER', 'ADMIN') OR lesson.status = 'published')
    )
  );

DROP POLICY IF EXISTS "Manage lesson school teachers" ON public.lesson;
CREATE POLICY "Manage lesson school teachers" ON public.lesson
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = lesson.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = lesson.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER','ADMIN'))
  );

-- 4.8 Policies: resource
DROP POLICY IF EXISTS "Select resource school members" ON public.resource;
CREATE POLICY "Select resource school members" ON public.resource
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.school_members sm 
      WHERE sm.school_id = resource.school_id 
      AND sm.user_id = auth.uid()
      AND (
        sm.role IN ('TEACHER', 'ADMIN')
        OR EXISTS (SELECT 1 FROM public.lesson l WHERE l.id = resource.lesson_id AND l.status = 'published')
      )
    )
  );

DROP POLICY IF EXISTS "Manage resource school teachers" ON public.resource;
CREATE POLICY "Manage resource school teachers" ON public.resource
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = resource.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER', 'ADMIN'))
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = resource.school_id AND sm.user_id = auth.uid() AND sm.role IN ('TEACHER', 'ADMIN'))
  );

-- 4.9 Policies: entitlements (Correção DT-05)
DROP POLICY IF EXISTS "Users can view own entitlements" ON public.entitlements;
CREATE POLICY "Users can view own entitlements" ON public.entitlements
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can manage school entitlements" ON public.entitlements;
CREATE POLICY "Admins can manage school entitlements" ON public.entitlements
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = entitlements.school_id AND sm.user_id = auth.uid() AND sm.role = 'ADMIN')
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.school_members sm WHERE sm.school_id = entitlements.school_id AND sm.user_id = auth.uid() AND sm.role = 'ADMIN')
  );

-- 4.10 Policies: course_watchlist
DROP POLICY IF EXISTS "Users can view their own watchlist" ON public.course_watchlist;
CREATE POLICY "Users can view their own watchlist" ON public.course_watchlist
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert into their own watchlist" ON public.course_watchlist;
CREATE POLICY "Users can insert into their own watchlist" ON public.course_watchlist
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete from their own watchlist" ON public.course_watchlist;
CREATE POLICY "Users can delete from their own watchlist" ON public.course_watchlist
  FOR DELETE USING (auth.uid() = user_id);

-- 4.11 Policies: diagnostic_*
DROP POLICY IF EXISTS "Public Read Access to Questions" ON public.diagnostic_questions;
CREATE POLICY "Public Read Access to Questions" ON public.diagnostic_questions
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Public Read Access to Options" ON public.diagnostic_options;
CREATE POLICY "Public Read Access to Options" ON public.diagnostic_options
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can view their own results" ON public.user_diagnostic_results;
CREATE POLICY "Users can view their own results" ON public.user_diagnostic_results
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own results" ON public.user_diagnostic_results;
CREATE POLICY "Users can update their own results" ON public.user_diagnostic_results
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- =============================================================================
-- 5. SUPABASE STORAGE BUCKETS & POLICIES
-- =============================================================================

INSERT INTO storage.buckets (id, name, public)
VALUES 
  ('course-thumbnails', 'course-thumbnails', true),
  ('lesson-resources', 'lesson-resources', true),
  ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

-- 5.1 Policies para course-thumbnails
DROP POLICY IF EXISTS "Public Read Access" ON storage.objects;
CREATE POLICY "Public Read Access" ON storage.objects
  FOR SELECT USING (bucket_id = 'course-thumbnails');

DROP POLICY IF EXISTS "Teacher Upload Access" ON storage.objects;
CREATE POLICY "Teacher Upload Access" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (
    bucket_id = 'course-thumbnails' AND
    EXISTS (SELECT 1 FROM public.users_profile WHERE users_profile.id = auth.uid() AND users_profile.role IN ('TEACHER', 'ADMIN'))
  );

DROP POLICY IF EXISTS "Teacher Update/Delete Own Access" ON storage.objects;
CREATE POLICY "Teacher Update/Delete Own Access" ON storage.objects
  FOR ALL TO authenticated USING (bucket_id = 'course-thumbnails' AND auth.uid() = owner);

-- 5.2 Policies para lesson-resources
DROP POLICY IF EXISTS "Teachers can upload lesson resources" ON storage.objects;
CREATE POLICY "Teachers can upload lesson resources" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (
    bucket_id = 'lesson-resources' AND
    EXISTS (
      SELECT 1 FROM public.school_members sm
      WHERE sm.school_id = (storage.foldername(name))[1]::uuid
      AND sm.user_id = auth.uid()
      AND sm.role IN ('TEACHER', 'ADMIN')
    )
  );

DROP POLICY IF EXISTS "Members can view lesson resources" ON storage.objects;
CREATE POLICY "Members can view lesson resources" ON storage.objects
  FOR SELECT TO authenticated USING (
    bucket_id = 'lesson-resources' AND
    EXISTS (
      SELECT 1 FROM public.school_members sm
      WHERE sm.school_id = (storage.foldername(name))[1]::uuid
      AND sm.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Teachers can delete lesson resources" ON storage.objects;
CREATE POLICY "Teachers can delete lesson resources" ON storage.objects
  FOR DELETE TO authenticated USING (
    bucket_id = 'lesson-resources' AND
    EXISTS (
      SELECT 1 FROM public.school_members sm
      WHERE sm.school_id = (storage.foldername(name))[1]::uuid
      AND sm.user_id = auth.uid()
      AND sm.role IN ('TEACHER', 'ADMIN')
    )
  );

DROP POLICY IF EXISTS "Teachers can update lesson resources" ON storage.objects;
CREATE POLICY "Teachers can update lesson resources" ON storage.objects
  FOR UPDATE TO authenticated USING (
    bucket_id = 'lesson-resources' AND
    EXISTS (
      SELECT 1 FROM public.school_members sm
      WHERE sm.school_id = (storage.foldername(name))[1]::uuid
      AND sm.user_id = auth.uid()
      AND sm.role IN ('TEACHER', 'ADMIN')
    )
  );

-- 5.3 Policies para avatars
DROP POLICY IF EXISTS "Public View Avatars" ON storage.objects;
CREATE POLICY "Public View Avatars" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "Users Upload Own Avatar" ON storage.objects;
CREATE POLICY "Users Upload Own Avatar" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'avatars' AND auth.uid() = owner);

DROP POLICY IF EXISTS "Users Update Own Avatar" ON storage.objects;
CREATE POLICY "Users Update Own Avatar" ON storage.objects
  FOR UPDATE TO authenticated USING (bucket_id = 'avatars' AND auth.uid() = owner);

DROP POLICY IF EXISTS "Users Delete Own Avatar" ON storage.objects;
CREATE POLICY "Users Delete Own Avatar" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'avatars' AND auth.uid() = owner);

-- =============================================================================
-- 6. DADOS INICIAIS (SEED DA ESCOLA PADRÃO E DIAGNÓSTICO)
-- =============================================================================

INSERT INTO public.schools (name, slug)
VALUES ('Escola do Empreendedor Raiz', 'escola-raiz')
ON CONFLICT (slug) DO NOTHING;

DO $$ 
DECLARE 
    v_school_id UUID;
    v_q1_id UUID;
    v_q2_id UUID;
BEGIN
    SELECT id INTO v_school_id FROM public.schools WHERE slug = 'escola-raiz';
    
    IF v_school_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.diagnostic_questions WHERE school_id = v_school_id
    ) THEN
        -- Pergunta 1
        INSERT INTO public.diagnostic_questions (school_id, text, description, "order")
        VALUES (v_school_id, 'Qual é o seu momento atual?', 'Queremos entender onde você está para te levar mais longe.', 1)
        RETURNING id INTO v_q1_id;

        INSERT INTO public.diagnostic_options (question_id, text, icon, mapped_categories, "order")
        VALUES 
        (v_q1_id, 'Estou começando agora do zero', '🌱', '["iniciante", "mentalidade"]'::jsonb, 1),
        (v_q1_id, 'Já tenho um negócio e quero escalar', '🚀', '["escala", "gestão", "marketing"]'::jsonb, 2),
        (v_q1_id, 'Sou um profissional liberal buscando autoridade', '💼', '["branding", "vendas"]'::jsonb, 3);

        -- Pergunta 2
        INSERT INTO public.diagnostic_questions (school_id, text, description, "order")
        VALUES (v_school_id, 'Qual dessas áreas é sua prioridade hoje?', 'Isso nos ajuda a montar sua primeira trilha.', 2)
        RETURNING id INTO v_q2_id;

        INSERT INTO public.diagnostic_options (question_id, text, icon, mapped_categories, "order")
        VALUES 
        (v_q2_id, 'Marketing & Vendas', '💰', '["marketing", "vendas"]'::jsonb, 1),
        (v_q2_id, 'Gestão & Processos', '⚙️', '["gestão", "processos", "financeiro"]'::jsonb, 2),
        (v_q2_id, 'Liderança & Equipes', '👥', '["liderança", "equipes", "rh"]'::jsonb, 3),
        (v_q2_id, 'Inteligência Artificial & Tech', '🤖', '["ia", "tecnologia", "automação"]'::jsonb, 4);
    END IF;
END $$;

