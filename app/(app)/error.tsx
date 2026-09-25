"use client";

import { AlertTriangle, RotateCcw } from "lucide-react";

export default function Erro({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const msg = error.message && !/Server Components render|digest/i.test(error.message) ? error.message : null;
  return (
    <div className="mx-auto mt-16 max-w-md text-center">
      <span className="mx-auto mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-warn-soft text-warn-ink"><AlertTriangle size={18} /></span>
      <h1 className="text-[15px] font-semibold text-ink">Não foi possível concluir a ação</h1>
      <p className="mt-1 text-[13px] text-muted">
        {msg ?? "Talvez você não tenha permissão para alterar isto (cada etapa só pode ser alterada pela área responsável ou por um administrador). Se achar que é um erro, fale com o administrador."}
      </p>
      <button type="button" onClick={() => reset()} className="btn-ghost mt-4"><RotateCcw size={14} /> Voltar</button>
    </div>
  );
}
