'use client';

import { useEffect, useState } from 'react';

const PRODUCTION_HOST = 'campus-online-saas.triadetecnologiaesolucoes.workers.dev';

export default function EnvBanner() {
  const [isPreview, setIsPreview] = useState(false);

  useEffect(() => {
    const hostname = window.location.hostname;
    const shouldShow =
      hostname.endsWith('.workers.dev') && hostname !== PRODUCTION_HOST;

    setIsPreview(shouldShow);

    if (shouldShow) {
      document.body.style.paddingTop = '28px';
    }

    return () => {
      if (shouldShow) {
        document.body.style.paddingTop = '';
      }
    };
  }, []);

  if (!isPreview) return null;

  return (
    <div className="fixed top-0 left-0 right-0 h-[28px] bg-amber-500 text-slate-950 z-[9999] flex items-center justify-center px-4 text-xs font-extrabold tracking-wide uppercase shadow-md">
      AMBIENTE DE PREVIEW — dados reais do banco de produção
    </div>
  );
}
