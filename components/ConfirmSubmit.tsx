"use client";

import { useFormStatus } from "react-dom";

export default function ConfirmSubmit({
  children, mensagem, className = "btn-primary",
}: { children: React.ReactNode; mensagem?: string; className?: string }) {
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      className={className}
      disabled={pending}
      onClick={(e) => { if (mensagem && !window.confirm(mensagem)) e.preventDefault(); }}
    >
      {pending ? "Salvando…" : children}
    </button>
  );
}
