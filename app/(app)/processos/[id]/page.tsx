import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { Evento, Processo, ProcessoEtapa, Profile } from "@/lib/types";
import { dataBR, dataHoraBR, mapaPerfis, nomesResponsaveis, PLANO_COR } from "@/lib/format";
import { addDiasUteis, diasUteisEntre, hojeBR, paraDataBR } from "@/lib/diasUteis";
import ConfirmSubmit from "@/components/ConfirmSubmit";
import {
  alterarPrazo, alterarResponsaveis, avancarProcesso, cancelarProcesso, comentar, editarProcesso, retornarProcesso,
} from "@/app/actions";

export const dynamic = "force-dynamic";

const STATUS_PROC: Record<string, string> = {
  ativo: "bg-indigo-100 text-indigo-800",
  concluido: "bg-emerald-100 text-emerald-800",
  cancelado: "bg-slate-200 text-slate-700",
};

export default async function DetalheProcesso({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: proc }, { data: etapasData }, { data: eventosData }, { data: perfisData }, { data: feriadosData }] = await Promise.all([
    supabase.from("processos").select("*").eq("id", id).maybeSingle(),
    supabase.from("processo_etapas").select("*").eq("processo_id", id).order("ordem"),
    supabase.from("processo_eventos").select("*").eq("processo_id", id).order("created_at", { ascending: false }),
    supabase.from("profiles").select("id,nome,email").order("nome"),
    supabase.from("feriados").select("data"),
  ]);
  if (!proc) notFound();

  const p = proc as Processo;
  const etapas = (etapasData ?? []) as ProcessoEtapa[];
  const eventos = (eventosData ?? []) as Evento[];
  const perfis = (perfisData ?? []) as Profile[];
  const mapa = mapaPerfis(perfis);
  const feriados = new Set((feriadosData ?? []).map((f: { data: string }) => f.data));
  const hoje = hojeBR();
  const atual = etapas.find((e) => e.status === "em_andamento");
  const idxAtual = atual ? etapas.indexOf(atual) : -1;

  // previsão de chegada = prazo da etapa atual + prazos das etapas seguintes
  let previsao: string | null = null;
  if (p.status === "ativo" && atual) {
    const base = atual.prazo_em && atual.prazo_em > hoje ? atual.prazo_em : hoje;
    const resto = etapas.slice(idxAtual + 1).reduce((s, e) => s + (e.prazo_dias_uteis ?? 0), 0);
    previsao = addDiasUteis(base, resto, feriados);
  }
  const previsaoAtrasada = atual?.prazo_em && atual.prazo_em < hoje;

  return (
    <div className="space-y-6">
      <Link href="/processos" className="text-sm text-slate-500 hover:text-slate-900">← Processos</Link>

      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-sm text-slate-500">{p.codigo} · aberto em {dataBR(p.created_at)}</p>
          <h1 className="text-2xl font-semibold">{p.cliente}</h1>
          <div className="mt-2 flex flex-wrap gap-2">
            <span className={`chip ${STATUS_PROC[p.status]}`}>{p.status === "ativo" ? "Em andamento" : p.status === "concluido" ? "Concluído" : "Cancelado"}</span>
            {p.plano && <span className={`chip ${PLANO_COR[p.plano]}`}>{p.plano}</span>}
          </div>
          {p.descricao && <p className="mt-2 max-w-2xl text-sm text-slate-600">{p.descricao}</p>}
        </div>
        <div className="card min-w-56 p-4">
          <p className="text-xs text-slate-500">{p.status === "concluido" ? "Chegou em" : "Previsão de chegada"}</p>
          <p className={`text-2xl font-semibold ${previsaoAtrasada ? "text-red-600" : ""}`}>
            {p.status === "concluido" ? dataBR(p.concluido_em ? paraDataBR(p.concluido_em) : null) : dataBR(previsao)}
          </p>
          {p.status === "ativo" && <p className="text-xs text-slate-500">considerando os prazos padrão das próximas etapas</p>}
        </div>
      </div>

      {p.status === "ativo" && atual && (
        <section className="card border-indigo-200 p-4">
          <p className="text-xs font-semibold uppercase tracking-wide text-indigo-600">Etapa atual · {atual.area}</p>
          <h2 className="text-lg font-semibold">{atual.nome}</h2>
          <p className="text-sm text-slate-600">
            Responsável: {nomesResponsaveis(atual.responsaveis, atual.responsaveis_label, mapa)} · Iniciada em {dataHoraBR(atual.iniciado_em)} · Prazo {dataBR(atual.prazo_em)}
          </p>

          <div className="mt-4 grid gap-4 lg:grid-cols-3">
            <form action={avancarProcesso} className="space-y-2">
              <input type="hidden" name="processo_id" value={p.id} />
              <label className="label">Observação (opcional)</label>
              <textarea name="obs" rows={2} className="input" placeholder="Ex.: booking confirmado, nº 12345" />
              <ConfirmSubmit mensagem={`Concluir "${atual.nome}" e passar para a próxima etapa?`}>
                ✓ Concluir etapa e avançar
              </ConfirmSubmit>
            </form>

            <form action={alterarPrazo} className="space-y-2">
              <input type="hidden" name="processo_id" value={p.id} />
              <input type="hidden" name="pe_id" value={atual.id} />
              <input type="hidden" name="etapa_nome" value={atual.nome} />
              <label className="label">{atual.prazo_editavel ? "Data prevista (ex.: ETA da viagem)" : "Ajustar prazo desta etapa"}</label>
              <input type="date" name="prazo_em" defaultValue={atual.prazo_em ?? ""} className="input" />
              <ConfirmSubmit className="btn-ghost">Salvar prazo</ConfirmSubmit>
            </form>

            <form action={alterarResponsaveis} className="space-y-2">
              <input type="hidden" name="processo_id" value={p.id} />
              <input type="hidden" name="pe_id" value={atual.id} />
              <input type="hidden" name="etapa_nome" value={atual.nome} />
              <label className="label">Responsáveis desta etapa</label>
              <div className="max-h-28 space-y-1 overflow-y-auto rounded-lg border border-slate-200 p-2">
                {perfis.map((pf) => (
                  <label key={pf.id} className="flex items-center gap-2 text-sm">
                    <input type="checkbox" name="responsaveis" value={pf.id} defaultChecked={atual.responsaveis.includes(pf.id)} />
                    {pf.nome ?? pf.email}
                  </label>
                ))}
                {!perfis.length && <p className="text-xs text-slate-500">Nenhum usuário cadastrado</p>}
              </div>
              <ConfirmSubmit className="btn-ghost">Salvar responsáveis</ConfirmSubmit>
            </form>
          </div>
        </section>
      )}

      <section className="card overflow-hidden">
        <div className="border-b border-slate-100 px-4 py-3"><h2 className="font-medium">Linha do tempo</h2></div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[820px] text-sm">
            <thead className="bg-slate-50 text-left text-xs text-slate-500">
              <tr>
                <th className="px-4 py-2 font-medium">Etapa</th>
                <th className="px-4 py-2 font-medium">Responsável</th>
                <th className="px-4 py-2 font-medium">Início</th>
                <th className="px-4 py-2 font-medium">Prazo</th>
                <th className="px-4 py-2 font-medium">Conclusão</th>
                <th className="px-4 py-2 text-right font-medium">Previsto</th>
                <th className="px-4 py-2 text-right font-medium">Realizado</th>
              </tr>
            </thead>
            <tbody>
              {etapas.map((e) => {
                const ini = e.iniciado_em ? paraDataBR(e.iniciado_em) : null;
                const fim = e.concluido_em ? paraDataBR(e.concluido_em) : e.status === "em_andamento" ? hoje : null;
                const real = ini && fim ? diasUteisEntre(ini, fim, feriados) : null;
                const atrasou = e.prazo_em && fim && fim > e.prazo_em;
                const icone = e.status === "concluida" ? "●" : e.status === "em_andamento" ? "◉" : "○";
                const corIcone = e.status === "concluida" ? (atrasou ? "text-red-500" : "text-emerald-500") : e.status === "em_andamento" ? "text-indigo-600" : "text-slate-300";
                return (
                  <tr key={e.id} className={`border-t border-slate-100 ${e.status === "em_andamento" ? "bg-indigo-50/50" : ""}`}>
                    <td className="px-4 py-2">
                      <div className="flex items-center gap-2">
                        <span className={corIcone}>{icone}</span>
                        <div>
                          <div className="text-[11px] text-slate-400">{e.area}</div>
                          <div className={e.status === "pendente" ? "text-slate-500" : "font-medium"}>{e.nome}</div>
                        </div>
                      </div>
                    </td>
                    <td className="px-4 py-2 text-slate-600">{nomesResponsaveis(e.responsaveis, e.responsaveis_label, mapa)}</td>
                    <td className="px-4 py-2">{ini ? dataBR(ini) : "—"}</td>
                    <td className="px-4 py-2">{dataBR(e.prazo_em)}</td>
                    <td className="px-4 py-2">{e.concluido_em ? dataBR(paraDataBR(e.concluido_em)) : "—"}</td>
                    <td className="px-4 py-2 text-right tabular-nums text-slate-500">{e.prazo_dias_uteis ?? "—"}</td>
                    <td className={`px-4 py-2 text-right tabular-nums ${atrasou ? "font-semibold text-red-600" : ""}`}>
                      {real === null ? "—" : `${real}${e.status === "em_andamento" ? "…" : ""}`}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <p className="border-t border-slate-100 px-4 py-2 text-xs text-slate-500">Previsto e realizado em dias úteis (sem fins de semana e feriados cadastrados).</p>
      </section>

      <div className="grid gap-6 lg:grid-cols-[2fr_1fr]">
        <section className="card p-4">
          <h2 className="mb-3 font-medium">Histórico e comentários</h2>
          <form action={comentar} className="mb-4 flex gap-2">
            <input type="hidden" name="processo_id" value={p.id} />
            <input name="texto" className="input" placeholder="Escreva um comentário…" required />
            <ConfirmSubmit className="btn-ghost">Enviar</ConfirmSubmit>
          </form>
          <ul className="space-y-3">
            {eventos.map((ev) => (
              <li key={ev.id} className="text-sm">
                <div className="text-xs text-slate-400">
                  {dataHoraBR(ev.created_at)} · {ev.autor ? mapa.get(ev.autor)?.nome ?? "—" : "Sistema"}
                </div>
                <p className={`whitespace-pre-line ${ev.tipo === "comentario" ? "" : "text-slate-600"}`}>{ev.texto}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="space-y-4">
          <details className="card p-4">
            <summary className="cursor-pointer font-medium">Editar dados do processo</summary>
            <form action={editarProcesso} className="mt-3 space-y-2">
              <input type="hidden" name="processo_id" value={p.id} />
              <div><label className="label">Cliente</label><input name="cliente" defaultValue={p.cliente} className="input" required /></div>
              <div>
                <label className="label">Plano</label>
                <select name="plano" defaultValue={p.plano ?? ""} className="input">
                  <option value="">—</option><option>Flex</option><option>Premium</option><option>Full</option>
                </select>
              </div>
              <div><label className="label">Descrição</label><textarea name="descricao" defaultValue={p.descricao ?? ""} rows={3} className="input" /></div>
              <ConfirmSubmit className="btn-ghost">Salvar</ConfirmSubmit>
            </form>
          </details>

          {(p.status === "concluido" || (atual && idxAtual > 0)) && (
            <details className="card p-4">
              <summary className="cursor-pointer font-medium">Voltar uma etapa</summary>
              <form action={retornarProcesso} className="mt-3 space-y-2">
                <input type="hidden" name="processo_id" value={p.id} />
                <input name="motivo" className="input" placeholder="Motivo (ex.: avancei por engano)" />
                <ConfirmSubmit className="btn-ghost" mensagem="Voltar o processo para a etapa anterior?">Voltar etapa</ConfirmSubmit>
              </form>
            </details>
          )}

          {p.status !== "concluido" && (
            <details className="card p-4">
              <summary className="cursor-pointer font-medium">{p.status === "cancelado" ? "Reativar processo" : "Cancelar processo"}</summary>
              <form action={cancelarProcesso} className="mt-3 space-y-2">
                <input type="hidden" name="processo_id" value={p.id} />
                {p.status === "cancelado" ? (
                  <><input type="hidden" name="reativar" value="1" /><ConfirmSubmit className="btn-ghost">Reativar</ConfirmSubmit></>
                ) : (
                  <>
                    <input name="motivo" className="input" placeholder="Motivo" />
                    <ConfirmSubmit className="btn-danger" mensagem="Cancelar este processo?">Cancelar processo</ConfirmSubmit>
                  </>
                )}
              </form>
            </details>
          )}
        </section>
      </div>
    </div>
  );
}
