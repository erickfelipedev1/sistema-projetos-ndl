import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import type { Etapa, EtapaAtual, Processo, Profile } from "@/lib/types";
import { dataBR, mapaPerfis, PLANO_COR } from "@/lib/format";
import CardProcesso from "@/components/CardProcesso";
import ConfirmSubmit from "@/components/ConfirmSubmit";
import { criarProcesso } from "@/app/actions";

export const dynamic = "force-dynamic";

type SP = Promise<{ [k: string]: string | undefined }>;

export default async function Processos({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const visao = sp.visao ?? "ativos";
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  const [{ data: etapas }, { data: perfis }] = await Promise.all([
    supabase.from("etapas").select("*").eq("ativo", true).order("ordem"),
    supabase.from("profiles").select("id,nome,email").order("nome"),
  ]);
  const mapa = mapaPerfis(perfis as Profile[]);

  const filtros = (
    <form className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="visao" value={visao} />
      <div>
        <label className="label">Cliente</label>
        <input name="q" defaultValue={sp.q ?? ""} placeholder="Buscar…" className="input w-44" />
      </div>
      {visao === "ativos" && (
        <div>
          <label className="label">Responsável</label>
          <select name="resp" defaultValue={sp.resp ?? ""} className="input w-44">
            <option value="">Todos</option>
            <option value="me">Eu</option>
            {(perfis as Profile[] ?? []).map((p) => <option key={p.id} value={p.id}>{p.nome ?? p.email}</option>)}
          </select>
        </div>
      )}
      <div>
        <label className="label">Plano</label>
        <select name="plano" defaultValue={sp.plano ?? ""} className="input w-32">
          <option value="">Todos</option>
          <option>Flex</option><option>Premium</option><option>Full</option>
        </select>
      </div>
      <button className="btn-ghost">Filtrar</button>
    </form>
  );

  const abas = (
    <div className="flex gap-1 rounded-lg bg-slate-100 p-1 text-sm">
      {[["ativos", "Em andamento"], ["concluido", "Concluídos"], ["cancelado", "Cancelados"]].map(([v, l]) => (
        <Link key={v} href={`/processos?visao=${v}`}
          className={`rounded-md px-3 py-1 ${visao === v ? "bg-white font-medium shadow-sm" : "text-slate-600"}`}>{l}</Link>
      ))}
    </div>
  );

  const novo = (
    <details open={sp.novo === "1"} className="card group">
      <summary className="flex cursor-pointer list-none items-center justify-between px-4 py-3 font-medium">
        <span>+ Novo processo</span>
        <span className="text-xs text-slate-400 group-open:hidden">clique para abrir</span>
      </summary>
      <form action={criarProcesso} className="grid gap-3 border-t border-slate-100 p-4 sm:grid-cols-[2fr_1fr_3fr_auto] sm:items-end">
        <div>
          <label className="label">Cliente *</label>
          <input name="cliente" required className="input" />
        </div>
        <div>
          <label className="label">Plano</label>
          <select name="plano" className="input" defaultValue="">
            <option value="">—</option>
            <option>Flex</option><option>Premium</option><option>Full</option>
          </select>
        </div>
        <div>
          <label className="label">Descrição / referência</label>
          <input name="descricao" className="input" placeholder="Ex.: container 40HC, origem Xangai" />
        </div>
        <ConfirmSubmit>Criar e iniciar fluxo</ConfirmSubmit>
      </form>
    </details>
  );

  if (visao !== "ativos") {
    let q = supabase.from("processos").select("*").eq("status", visao).order("created_at", { ascending: false }).limit(200);
    if (sp.q) q = q.ilike("cliente", `%${sp.q}%`);
    if (sp.plano) q = q.eq("plano", sp.plano);
    const { data } = await q;
    const lista = (data ?? []) as Processo[];
    return (
      <div className="space-y-4">
        <div className="flex flex-wrap items-end justify-between gap-3">{abas}{filtros}</div>
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[640px] text-sm">
            <thead className="bg-slate-50 text-left text-xs text-slate-500">
              <tr><th className="px-4 py-2">Código</th><th className="px-4 py-2">Cliente</th><th className="px-4 py-2">Plano</th><th className="px-4 py-2">Aberto em</th><th className="px-4 py-2">{visao === "concluido" ? "Concluído em" : ""}</th></tr>
            </thead>
            <tbody>
              {lista.map((p) => (
                <tr key={p.id} className="border-t border-slate-100 hover:bg-slate-50">
                  <td className="px-4 py-2 text-slate-500"><Link href={`/processos/${p.id}`}>{p.codigo}</Link></td>
                  <td className="px-4 py-2 font-medium"><Link href={`/processos/${p.id}`}>{p.cliente}</Link></td>
                  <td className="px-4 py-2">{p.plano && <span className={`chip ${PLANO_COR[p.plano]}`}>{p.plano}</span>}</td>
                  <td className="px-4 py-2">{dataBR(p.created_at)}</td>
                  <td className="px-4 py-2">{visao === "concluido" ? dataBR(p.concluido_em) : ""}</td>
                </tr>
              ))}
              {!lista.length && <tr><td colSpan={5} className="px-4 py-6 text-center text-slate-500">Nenhum processo.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    );
  }

  let q = supabase.from("v_etapas_atuais").select("*").order("prazo_em", { ascending: true, nullsFirst: false });
  if (sp.q) q = q.ilike("cliente", `%${sp.q}%`);
  if (sp.plano) q = q.eq("plano", sp.plano);
  if (sp.resp) q = q.contains("responsaveis", [sp.resp === "me" ? user!.id : sp.resp]);
  const { data: atuais } = await q;
  const lista = (atuais ?? []) as EtapaAtual[];
  const colunas = ((etapas ?? []) as Etapa[]).filter((e) => e.tipo !== "final");
  const idsColunas = new Set(colunas.map((c) => c.id));
  const orfaos = lista.filter((e) => !e.etapa_id || !idsColunas.has(e.etapa_id));

  return (
    <div className="space-y-4">
      {novo}
      <div className="flex flex-wrap items-end justify-between gap-3">{abas}{filtros}</div>
      <div className="-mx-4 overflow-x-auto px-4 pb-4">
        <div className="flex gap-3">
          {colunas.map((c) => {
            const cards = lista.filter((e) => e.etapa_id === c.id);
            const atras = cards.filter((e) => e.atrasada).length;
            return (
              <div key={c.id} className="flex w-64 shrink-0 flex-col rounded-xl bg-slate-100/80 p-2">
                <div className="mb-2 px-1">
                  <div className="flex items-center justify-between">
                    <span className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">{c.area}</span>
                    <span className="text-xs tabular-nums text-slate-500">
                      {cards.length}{atras > 0 && <span className="ml-1 font-semibold text-red-600">· {atras} atras.</span>}
                    </span>
                  </div>
                  <p className="text-sm font-medium leading-tight">{c.nome}</p>
                  <p className="text-[11px] text-slate-500">
                    {c.prazo_dias_uteis === null ? "Sem prazo" : c.tipo === "marco" ? "Marco" : `${c.prazo_dias_uteis} d.u.`}
                    {c.responsaveis_label ? ` · ${c.responsaveis_label}` : ""}
                  </p>
                </div>
                <div className="flex flex-col gap-2">
                  {cards.map((e) => <CardProcesso key={e.id} e={e} perfis={mapa} />)}
                </div>
              </div>
            );
          })}
          {orfaos.length > 0 && (
            <div className="flex w-64 shrink-0 flex-col gap-2 rounded-xl bg-slate-100/80 p-2">
              <p className="px-1 text-sm font-medium">Etapas removidas da configuração</p>
              {orfaos.map((e) => <CardProcesso key={e.id} e={e} perfis={mapa} mostrarEtapa />)}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
