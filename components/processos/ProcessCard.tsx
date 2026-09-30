import Link from "next/link";
import type { EtapaAtual, Profile } from "@/lib/types";
import { motivo, prazoTexto, statusPrazo } from "@/lib/status";
import { dataBR } from "@/lib/format";
import { StatusDot } from "@/components/ui/StatusBadge";
import ProgressBar from "@/components/ui/ProgressBar";
import Avatar from "@/components/ui/Avatar";

export const PLANO_ESTILO: Record<string, string> = {
  Flex: "bg-[#eef4fa] text-[#2f6b9a]",
  Full: "bg-[#e9eef6] text-[#123b63]",
  Premium: "bg-[#123b63] text-white",
};

export function PlanoTag({ plano }: { plano: string | null }) {
  if (!plano) return null;
  return <span className={`chip ${PLANO_ESTILO[plano] ?? "bg-sunken text-muted"}`}>{plano}</span>;
}

/** card compacto do kanban: empresa, plano, responsável, prazo, motivo e checklist */
export default function ProcessCard({ e, mapa }: { e: EtapaAtual; mapa: Map<string, Profile> }) {
  const st = statusPrazo(e.dias_restantes, e.atrasada, e);
  const nomes = e.responsaveis.map((id) => mapa.get(id)?.nome).filter(Boolean) as string[];
  const corPrazo = { atrasado: "text-bad-ink", atencao: "text-warn-ink", em_dia: "text-muted", sem_prazo: "text-subtle", aguardando: "text-primary", cobrar: "text-warn-ink" }[st as "atrasado"] ?? "text-muted";
  return (
    <Link href={`/processos/${e.processo_id}`}
      className={`group block rounded-md border bg-surface p-2.5 transition hover:border-primary-2/50 hover:shadow-[var(--shadow-card)] ${st === "atrasado" ? "border-[#f0c9c9]" : "border-line"}`}>
      <div className="flex items-start justify-between gap-2">
        <p className="line-clamp-1 text-[13px] leading-tight font-semibold text-ink group-hover:text-primary">{e.cliente}</p>
        <PlanoTag plano={e.plano} />
      </div>
      <p className="mt-0.5 line-clamp-1 text-[11.5px] text-muted" title={motivo(e)}>{motivo(e)}</p>
      <div className="mt-2 flex items-center justify-between gap-2">
        <span className="flex min-w-0 items-center gap-1.5 text-[11.5px] text-ink">
          {nomes.length ? <Avatar nome={nomes[0]} tamanho={18} /> : null}
          <span className="truncate">{nomes.length ? nomes.join(" / ") : <span className="text-muted">{e.responsaveis_label ?? "—"}</span>}</span>
        </span>
        <span className={`inline-flex shrink-0 items-center gap-1 text-[11.5px] font-medium ${corPrazo}`} title={`Prazo ${dataBR(e.prazo_em)}`}>
          <StatusDot tipo={st} />
          {prazoTexto(e.dias_restantes, e.atrasada, e).replace(" dias úteis", " d.u.").replace(" dia útil", " d.u.")}
        </span>
      </div>
      {e.checklist_total > 0 && <ProgressBar className="mt-2" valor={e.checklist_feitos} total={e.checklist_total} tom={e.checklist_feitos === e.checklist_total ? "ok" : "primary"} />}
      {(e.certificacao || e.gerenciamento) && (
        <div className="mt-1.5 flex gap-1">
          {e.gerenciamento && <span className="chip bg-sunken text-muted">{e.gerenciamento === "ntl" ? "NTL" : "Próprio NLG"}</span>}
          {e.certificacao && <span className="chip bg-sunken text-muted">Certificação</span>}
        </div>
      )}
    </Link>
  );
}
