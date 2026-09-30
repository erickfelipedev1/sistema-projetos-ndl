import { STATUS_LABEL, type StatusTipo } from "@/lib/status";

const ESTILO: Record<StatusTipo, string> = {
  atrasado: "bg-bad-soft text-bad-ink",
  atencao: "bg-warn-soft text-warn-ink",
  em_dia: "bg-ok-soft text-ok-ink",
  sem_prazo: "bg-sunken text-muted",
  concluido: "bg-ok-soft text-ok-ink",
  cancelado: "bg-sunken text-muted",
  pendente: "bg-sunken text-muted",
  aguardando: "bg-primary-soft text-primary",
  cobrar: "bg-warn-soft text-warn-ink",
};
const PONTO: Record<StatusTipo, string> = {
  atrasado: "bg-bad", atencao: "bg-warn", em_dia: "bg-ok", sem_prazo: "bg-subtle",
  concluido: "bg-ok", cancelado: "bg-subtle", pendente: "bg-subtle", aguardando: "bg-primary-2", cobrar: "bg-warn",
};

/** status sempre com ponto + texto — nunca só cor */
export default function StatusBadge({ tipo, texto, className = "" }: { tipo: StatusTipo; texto?: string; className?: string }) {
  return (
    <span className={`chip ${ESTILO[tipo]} ${className}`}>
      <span className={`h-1.5 w-1.5 rounded-full ${PONTO[tipo]}`} aria-hidden />
      {texto ?? STATUS_LABEL[tipo]}
    </span>
  );
}

export function StatusDot({ tipo }: { tipo: StatusTipo }) {
  return <span className={`inline-block h-2 w-2 shrink-0 rounded-full ${PONTO[tipo]}`} aria-label={STATUS_LABEL[tipo]} />;
}
