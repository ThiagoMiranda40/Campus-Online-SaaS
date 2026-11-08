import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';

export const dynamic = 'force-dynamic';

export async function GET() {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !supabaseAnonKey) {
        return NextResponse.json(
            { ok: false, error: 'Missing Supabase environment variables' },
            { status: 500 }
        );
    }

    try {
        const supabase = createClient(supabaseUrl, supabaseAnonKey);
        const { count, error } = await supabase
            .from('schools')
            .select('*', { count: 'exact', head: true });

        if (error) {
            return NextResponse.json(
                { ok: false, error: error.message },
                { status: 500 }
            );
        }

        return NextResponse.json({
            ok: true,
            service: 'campus-online-saas',
            schoolsCount: count ?? 0,
            timestamp: new Date().toISOString(),
        });
    } catch (err: any) {
        return NextResponse.json(
            { ok: false, error: err?.message || 'Unexpected error' },
            { status: 500 }
        );
    }
}

