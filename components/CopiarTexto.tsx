"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";

export default function CopiarTexto({ texto, rotulo = "Copiar mensagem", className = "btn-ghost" }: { texto: string; rotulo?: string; className?: string }) {
  const [ok, setOk] = useState(false);
  return (
    <button type="button" className={className}
      onClick={async () => { await navigator.clipboard.writeText(texto); setOk(true); setTimeout(() => setOk(false), 1800); }}>
      {ok ? <><Check size={14} /> Copiado</> : <><Copy size={14} /> {rotulo}</>}
    </button>
  );
}
