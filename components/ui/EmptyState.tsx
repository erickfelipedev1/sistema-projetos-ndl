import { Inbox } from "lucide-react";

export default function EmptyState({ titulo, texto, acao, compacto = false }: { titulo: string; texto?: string; acao?: React.ReactNode; compacto?: boolean }) {
  return (
    <div className={`flex flex-col items-center justify-center text-center ${compacto ? "py-6" : "py-12"}`}>
      <span className="mb-2 inline-flex h-9 w-9 items-center justify-center rounded-full bg-sunken text-subtle"><Inbox size={18} /></span>
      <p className="text-[13px] font-medium text-ink">{titulo}</p>
      {texto && <p className="mt-0.5 max-w-sm text-xs text-muted">{texto}</p>}
      {acao && <div className="mt-3">{acao}</div>}
    </div>
  );
}
