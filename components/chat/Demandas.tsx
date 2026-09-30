"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { Mensagem } from "@/lib/types";
import { relativo } from "@/lib/status";
import Avatar from "@/components/ui/Avatar";
import EmptyState from "@/components/ui/EmptyState";
import DemandaCard from "./DemandaCard";

export default function Demandas({ meuId, demandas, nomes, processos }: {
  meuId: string; demandas: Mensagem[]; nomes: Record<string, string>; processos: Record<string, string>;
}) {
  const router = useRouter();
  const [lista, setLista] = useState(demandas);
  const [aba, setAba] = useState<"minhas" | "pedi" | "concluidas">("minhas");
  const [erro, setErro] = useState<string | null>(null);

  async function mudar(m: Mensagem, status: "aberta" | "concluida") {
    const { data, error } = await createClient().from("mensagens")
      .update({ demanda_status: status, demanda_concluida_em: status === "concluida" ? new Date().toISOString() : null })
      .eq("id", m.id).select("*").single();
    if (error) return setErro(error.message);
    setLista((l) => l.map((x) => (x.id === m.id ? (data as Mensagem) : x)));
    router.refresh();
  }

  const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const ordenar = (a: Mensagem, b: Mensagem) => (a.demanda_prazo ?? "9999").localeCompare(b.demanda_prazo ?? "9999") || a.id - b.id;
  const grupos = {
    minhas: lista.filter((m) => m.demanda_para === meuId && m.demanda_status === "aberta").sort(ordenar),
    pedi: lista.filter((m) => m.autor === meuId && m.demanda_status === "aberta").sort(ordenar),
    concluidas: lista.filter((m) => m.demanda_status === "concluida").sort((a, b) => (b.demanda_concluida_em ?? "").localeCompare(a.demanda_concluida_em ?? "")),
  };
  const abas = [
    { k: "minhas" as const, t: "Para mim", n: grupos.minhas.length },
    { k: "pedi" as const, t: "Que eu pedi", n: grupos.pedi.length },
    { k: "concluidas" as const, t: "Concluídas", n: grupos.concluidas.length },
  ];
  const atrasadas = grupos.minhas.filter((m) => m.demanda_prazo && m.demanda_prazo < hoje).length;

  return (
    <div className="flex-1 overflow-y-auto px-4 py-4">
      <div className="mx-auto max-w-3xl">
        <h2 className="text-[15px] font-semibold text-ink">Demandas</h2>
        <p className="text-xs text-muted">Pedidos feitos pelo chat. {atrasadas > 0 && <span className="font-medium text-bad-ink">{atrasadas} das suas com prazo vencido.</span>}</p>
        <div role="tablist" className="mt-3 flex gap-1 border-b border-line">
          {abas.map((a) => (
            <button key={a.k} role="tab" aria-selected={aba === a.k} onClick={() => setAba(a.k)}
              className={`-mb-px border-b-2 px-3 py-2 text-[13px] ${aba === a.k ? "border-primary font-medium text-primary" : "border-transparent text-muted hover:text-ink"}`}>
              {a.t} <span className="num text-xs text-subtle">{a.n}</span>
            </button>
          ))}
        </div>
        {erro && <p className="mt-2 text-xs text-bad-ink">{erro}</p>}
        <ul className="mt-3 space-y-2">
          {grupos[aba].map((m) => (
            <li key={m.id} className="card px-3 py-2.5">
              <div className="flex items-start gap-2.5">
                <Avatar nome={nomes[m.autor]} tamanho={28} />
                <div className="min-w-0 flex-1">
                  <p className="text-[12.5px]">
                    <span className="font-semibold text-ink">{m.autor === meuId ? "Você" : nomes[m.autor] ?? "—"}</span>
                    <span className="text-subtle"> · {relativo(m.created_at)} · </span>
                    <Link href={`/chat?c=${m.conversa_id}`} className="text-primary-2 hover:underline">abrir conversa</Link>
                  </p>
                  <p className="text-[13.5px] whitespace-pre-wrap text-ink">{m.texto}</p>
                  <DemandaCard m={m} meuId={meuId} nomes={nomes} processo={m.processo_id ? processos[m.processo_id] : null} onStatus={mudar} />
                </div>
              </div>
            </li>
          ))}
        </ul>
        {grupos[aba].length === 0 && <EmptyState compacto titulo={aba === "minhas" ? "Nenhuma demanda aberta para você" : aba === "pedi" ? "Você não tem pedidos em aberto" : "Nenhuma demanda concluída"} />}
      </div>
    </div>
  );
}
