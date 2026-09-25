"use client";

import SubmitButton from "@/components/ui/SubmitButton";

/** compatibilidade: mesmo comportamento do SubmitButton */
export default function ConfirmSubmit({ children, mensagem, className = "btn-primary" }: { children: React.ReactNode; mensagem?: string; className?: string }) {
  return <SubmitButton className={className} confirmar={mensagem}>{children}</SubmitButton>;
}
