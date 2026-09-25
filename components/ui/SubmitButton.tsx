"use client";

import { useFormStatus } from "react-dom";

/** botão de envio com estado de carregamento e confirmação opcional */
export default function SubmitButton({ children, className = "btn-primary", confirmar, pendente = "Salvando…" }: {
  children: React.ReactNode; className?: string; confirmar?: string; pendente?: string;
}) {
  const { pending } = useFormStatus();
  return (
    <button type="submit" className={className} disabled={pending}
      onClick={(e) => { if (confirmar && !window.confirm(confirmar)) e.preventDefault(); }}>
      {pending ? pendente : children}
    </button>
  );
}
