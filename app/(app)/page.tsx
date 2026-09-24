import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import type { Desempenho, EtapaAtual, Profile } from "@/lib/types";
import { mapaPerfis } from "@/lib/format";
import CardProcesso from "@/components/CardProcesso";

export const dynamic = "force-dynamic";

export default async function Painel() {
  const supabase = await createClient();
  const inicioMes = new Date();
  inicioMes.setDate(1);
  inicioMes.setHours(0, 0, 0, 0);

  const [{ data: atuais }, { data: desempenho }, { data: perfis }, { count: concluidosMes }] = await Promise.all([
    supabase.from("v_etapas_atuais").select("*").order("prazo_em", { ascending: true, nullsFirst: false }),
    supabase.from("v_desempenho_etapas").select("*").order("ordem"),
    supabase.from("profiles").select("id,nome,email"),
    supabase.from("processos").select("id", { count: "exact", head: true })
      .eq("status", "concluido").gte("concluido_em", inicioMes.toISOString()),
  ]);

  const lista = (atuais ?? []) as EtapaAtual[];
  const desemp = ((desempenho ?? []) as Desempenho[]).filter((d) => d.tipo !== "final");
  const mapa = mapaPerfis(perfis as Profile[]);
  const atrasados = lista.filter((e) => e.atrasada);
  const vencendo = lista.filter((e) => !e.atrasada && e.dias_restantes !== null && e.dias_restantes <= 1);
  const maxAndamento = Math.max(1, ...desemp.map((d) => d.em_andamento));

  const kpis = [
    { label: "Processos ativos", valor: lista.length, cor: "text-slate-900" },
    { label: "Etapas atrasadas", valor: atrasados.length, cor: atrasados.length ? "text-red-600" : "text-slate-900" },
    { label: "Vencem hoje ou amanhã", valor: vencendo.length, cor: vencendo.length ? "text-amber-600" : "text-slate-900" },
    { label: "Concluídos no mês", valor: concluidosMes ?? 0, cor: "text-emerald-700" },
  ];

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold">Painel</h1>
        <Link href="/processos?novo=1" className="btn-primary">+ Novo processo</Link>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {kpis.map((k) => (
          <div key={k.label} className="card p-4">
            <p className="text-xs text-slate-500">{k.label}</p>
            <p className={`mt-1 text-3xl font-semibold tabular-nums ${k.cor}`}>{k.valor}</p>
          </div>
        ))}
      </div>

      <section className="card overflow-hidden">
        <div className="border-b border-slate-100 px-4 py-3">
          <h2 className="font-medium">Onde o fluxo está</h2>
          <p className="text-xs text-slate-500">Processos em cada etapa agora e tempo real médio (dias úteis) comparado ao prazo</p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-sm">
            <thead className="bg-slate-50 text-left text-xs text-slate-500">
              <tr>
                <th className="px-4 py-2 font-medium">Etapa</th>
                <th className="px-4 py-2 font-medium">Em andamento</th>
                <th className="px-4 py-2 text-right font-medium">Atrasadas</th>
                <th className="px-4 py-2 text-right font-medium">Prazo</th>
                <th className="px-4 py-2 text-right font-medium">Média real</th>
                <th className="px-4 py-2 text-right font-medium">No prazo</th>
              </tr>
            </thead>
            <tbody>
              {desemp.map((d) => {
                const noPrazo = d.concluidas ? Math.round(((d.concluidas - d.concluidas_com_atraso) / d.concluidas) * 100) : null;
                const acima = d.media_dias_uteis !== null && d.prazo_dias_uteis !== null && d.media_dias_uteis > d.prazo_dias_uteis;
                return (
                  <tr key={d.etapa_id} className="border-t border-slate-100">
                    <td className="px-4 py-2">
                      <span className="text-xs text-slate-400">{d.area}</span>
                      <div className="font-medium">{d.nome}</div>
                    </td>
                    <td className="px-4 py-2">
                      <div className="flex items-center gap-2">
                        <div className="h-2 w-32 rounded-full bg-slate-100">
                          <div className="h-2 rounded-full bg-indigo-500" style={{ width: `${(d.em_andamento / maxAndamento) * 100}%` }} />
                        </div>
                        <span className="tabular-nums">{d.em_andamento}</span>
                      </div>
                    </td>
                    <td className={`px-4 py-2 text-right tabular-nums ${d.atrasadas_agora ? "font-semibold text-red-600" : "text-slate-400"}`}>{d.atrasadas_agora}</td>
                    <td className="px-4 py-2 text-right tabular-nums text-slate-500">{d.prazo_dias_uteis ?? "—"}</td>
                    <td className={`px-4 py-2 text-right tabular-nums ${acima ? "font-semibold text-red-600" : ""}`}>{d.media_dias_uteis ?? "—"}</td>
                    <td className="px-4 py-2 text-right tabular-nums">{noPrazo === null ? "—" : `${noPrazo}%`}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <div className="grid gap-6 lg:grid-cols-2">
        <section>
          <h2 className="mb-2 font-medium text-red-700">Atrasados ({atrasados.length})</h2>
          <div className="grid gap-2 sm:grid-cols-2">
            {atrasados.slice(0, 12).map((e) => <CardProcesso key={e.id} e={e} perfis={mapa} mostrarEtapa />)}
            {!atrasados.length && <p className="text-sm text-slate-500">Nenhuma etapa atrasada.</p>}
          </div>
        </section>
        <section>
          <h2 className="mb-2 font-medium text-amber-700">Vencem hoje ou amanhã ({vencendo.length})</h2>
          <div className="grid gap-2 sm:grid-cols-2">
            {vencendo.slice(0, 12).map((e) => <CardProcesso key={e.id} e={e} perfis={mapa} mostrarEtapa />)}
            {!vencendo.length && <p className="text-sm text-slate-500">Nada vencendo nos próximos dias.</p>}
          </div>
        </section>
      </div>
    </div>
  );
}
