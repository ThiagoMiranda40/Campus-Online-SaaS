const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');
const path = require('path');

// Carregar .env.local sem depender do pacote 'dotenv'
const envPath = path.resolve(process.cwd(), '.env.local');
if (fs.existsSync(envPath)) {
    const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const eqIdx = trimmed.indexOf('=');
        if (eqIdx > 0) {
            const key = trimmed.slice(0, eqIdx).trim();
            const val = trimmed.slice(eqIdx + 1).trim().replace(/^['"]|['"]$/g, '');
            if (!process.env[key]) process.env[key] = val;
        }
    }
}

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
    console.error('Erro: Variáveis de ambiente não encontradas em .env.local');
    process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseAnonKey);

async function diagnostic() {
    console.log('--- DIAGNÓSTICO SUPABASE (CAMPUS ONLINE SAAS) ---');

    const tables = [
        'schools',
        'school_members',
        'users_profile',
        'category',
        'course',
        'module',
        'lesson',
        'resource',
        'entitlements',
        'course_watchlist',
        'diagnostic_questions',
        'diagnostic_options',
        'user_diagnostic_results'
    ];

    for (const table of tables) {
        const { count, error } = await supabase
            .from(table)
            .select('*', { count: 'exact', head: true });

        if (error) {
            console.log(`❌ Tabela [${table}]: Erro ou Sem Acesso (${error.message})`);
        } else {
            console.log(`✅ Tabela [${table}]: Conexão OK (${count ?? 0} registros visíveis via anon/RLS)`);
        }
    }
}

diagnostic();
