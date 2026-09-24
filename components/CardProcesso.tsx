import Link from "next/link";
import type { EtapaAtual, Profile } from "@/lib/types";
import { nomesResponsaveis, prazoCor, prazoTexto, PLANO_COR, dataBR } from "@/lib/format";

export default function CardProcesso({ e, perfis, mostrarEtapa = false }: { e: EtapaAtual; perfis: Map<string, Profile>; mostrarEtapa?: boolean }) {
  return (
    <Link href={`/processos/${e.processo_id}`}
      className={`card block p-3 transition hover:border-indigo-300 hover:shadow-sm ${e.atrasada ? "border-l-4 border-l-red-500" : ""}`}>
      <div className="flex items-center justify-between gap-2">
        <span className="text-[11px] font-medium text-slate-400">{e.codigo}</span>
        {e.plano && <span className={`chip ${PLANO_COR[e.plano] ?? ""}`}>{e.plano}</span>}
      </div>
      <p className="mt-1 font-medium leading-snug">{e.cliente}</p>
      {mostrarEtapa && <p className="text-xs text-slate-500">{e.area} · {e.nome}</p>}
      <p className="mt-1 text-xs text-slate-500">{nomesResponsaveis(e.responsaveis, e.responsaveis_label, perfis)}</p>
      <div className="mt-2 flex items-center justify-between gap-2">
        <span className={`chip ${prazoCor(e.dias_restantes, e.atrasada)}`}>{prazoTexto(e.dias_restantes, e.atrasada)}</span>
        <span className="text-[11px] text-slate-400">{dataBR(e.prazo_em)}</span>
      </div>
    </Link>
  );
}
