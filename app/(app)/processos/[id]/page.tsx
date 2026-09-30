import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowRight, CalendarClock, ChevronRight, CircleCheck, RotateCcw, XCircle, Pencil, RefreshCcw } from "lucide-react";
import { base, previsaoChegada, duracaoUteis } from "@/lib/dados";
import type { Anexo, ChecklistItem, EmailModelo, Evento, Processo, ProcessoEtapa } from "@/lib/types";
import { dataBR, dataHoraBR, nomesResponsaveis, preencherModelo, GERENCIAMENTO_LABEL } from "@/lib/format";
import { diasUteisEntre, paraDataBR } from "@/lib/diasUteis";
import { du, limparPasso, nomeCurto, prazoTexto, statusPrazo } from "@/lib/status";
import Tabs from "@/components/ui/Tabs";
import StatusBadge from "@/components/ui/StatusBadge";
import { Responsavel } from "@/components/ui/Avatar";
import Modal, { Drawer } from "@/components/ui/Modal";
import Menu from "@/components/ui/Menu";
import SubmitButton from "@/components/ui/SubmitButton";
import EmptyState from "@/components/ui/EmptyState";
import ActivityTimeline from "@/components/ui/ActivityTimeline";
import ProcessTimeline, { estadoDe } from "@/components/processos/ProcessTimeline";
import { PlanoTag } from "@/components/processos/ProcessCard";
import Checklist from "@/components/Checklist";
import EmailModelos from "@/components/EmailModelos";
import CobrancaForm from "@/components/processos/CobrancaForm";
import { Hourglass } from "lucide-react";
import Anexos, { AnexarBotao, type GrupoAnexos } from "@/components/anexos/Anexos";
import { podeEditarEtapa, podeMarcarItem, responsaveisDoItem } from "@/lib/permissoes";
import { Lock, Pause, Play } from "lucide-react";
import {
  alterarPrazo, alterarResponsaveis, avancarProcesso, cancelarProcesso, comentar, definirSituacao, editarProcesso, pausarProcesso, retornarProcesso,
} from "@/app/actions";

export const dynamic = "force-dynamic";

export default async function DetalheProcesso({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ tab?: string }> }) {
  const { id } = await params;
  const { tab = "checklist" } = await searchParams;
  const { supabase, user, perfis, mapaPerfis, feriados, hoje } = await base();

  const [{ data: proc }, { data: etapasData }, { data: eventosData }, { data: checkData }, { data: emailsData }, { data: anexosData }, { data: clientesData }] = await Promise.all([
    supabase.from("processos").select("*").eq("id", id).maybeSingle(),
    supabase.from("processo_etapas").select("*").eq("processo_id", id).order("ordem"),
    supabase.from("processo_eventos").select("*").eq("processo_id", id).order("created_at", { ascending: false }),
    supabase.from("processo_checklist").select("*, processo_etapas!inner(processo_id)").eq("processo_etapas.processo_id", id).order("ordem"),
    supabase.from("email_modelos").select("*").eq("ativo", true).order("ordem"),
    supabase.from("anexos").select("*").eq("processo_id", id).order("created_at", { ascending: false }),
    supabase.from("clientes").select("id,nome").order("nome"),
  ]);
  const { data: modelosResp } = await supabase.from("checklist_modelo").select("id,responsaveis,responsaveis_label");
  const respItens: Record<number, string> = Object.fromEntries(((modelosResp ?? []) as { id: number; responsaveis: string[]; responsaveis_label: string | null }[])
    .map((m) => [m.id, (m.responsaveis ?? []).map((r) => mapaPerfis.get(r)?.nome).filter(Boolean).join(" / ") || m.responsaveis_label || ""])
    .filter(([, v]) => v));
  const eu = perfis.find((pf) => pf.id === user.id);
  const modelosMap = new Map(((modelosResp ?? []) as { id: number; responsaveis: string[]; responsaveis_label: string | null }[]).map((m) => [m.id, m]));
  if (!proc) notFound();

  const p = proc as Processo;
  const etapas = (etapasData ?? []) as ProcessoEtapa[];
  const eventos = (eventosData ?? []) as Evento[];
  const checklist = (checkData ?? []) as ChecklistItem[];
  const atual = etapas.find((e) => e.status === "em_andamento");
  const idxAtual = atual ? etapas.indexOf(atual) : -1;
  const proxima = idxAtual >= 0 ? etapas[idxAtual + 1] : undefined;
  const nomes = Object.fromEntries(perfis.map((pf) => [pf.id, pf.nome ?? pf.email ?? ""]));
  const resp = (e: ProcessoEtapa) => nomesResponsaveis(e.responsaveis, e.responsaveis_label, mapaPerfis);

  const previsao = p.status === "ativo" ? previsaoChegada(etapas, feriados, hoje) : null;
  const diasAtual = atual?.prazo_em ? diasUteisEntre(hoje, atual.prazo_em, feriados) : null;
  const atrasada = !!(atual?.prazo_em && atual.prazo_em < hoje);
  const podeAtual = podeEditarEtapa(eu, atual);
  const podeProc = !!eu?.admin || (p.status !== "concluido" && podeAtual);
  const donoAtual = atual ? (atual.responsaveis.map((r) => mapaPerfis.get(r)?.nome).filter(Boolean).join(" / ") || atual.responsaveis_label || "") : "";
  const aguardando = !!atual?.aguardando_cliente;
  const baseCobranca = atual?.ultima_cobranca ?? atual?.aguardando_desde ?? null;
  const proximaCobranca = baseCobranca ? new Date(new Date(paraDataBR(baseCobranca) + "T12:00:00").getTime() + 7 * 86400000).toISOString().slice(0, 10) : null;
  const cobrarHoje = aguardando && !!proximaCobranca && proximaCobranca <= hoje;
  const diasEsperando = atual?.aguardando_desde ? diasUteisEntre(paraDataBR(atual.aguardando_desde), hoje, feriados) : 0;
  const espera = { aguardando_cliente: aguardando, cobrar_hoje: cobrarHoje };
  const stAtual = statusPrazo(diasAtual, atrasada, espera);
  const checkAtual = atual ? checklist.filter((c) => c.processo_etapa_id === atual.id) : [];
  const bloqueados: Record<string, string> = {};
  for (const c of checkAtual) {
    const resp = c.modelo_id ? responsaveisDoItem(modelosMap.get(c.modelo_id), perfis) : [];
    if (!podeMarcarItem(eu, resp, atual)) {
      bloqueados[c.id] = resp.length ? `Só ${resp.map((x) => mapaPerfis.get(x)?.nome).filter(Boolean).join(" / ")} pode marcar` : `Só ${atual?.area ?? "a área da etapa"} pode marcar`;
    }
  }
  const pendentes = checkAtual.filter((c) => !c.feito);
  const proximaAcao = atual?.situacao ?? (pendentes[0] ? limparPasso(pendentes[0].titulo) : null);

  const meuNome = perfis.find((pf) => pf.id === user.id)?.nome ?? null;
  const vars = { empresa: p.cliente, contato: p.contato, plano: p.plano, meu_nome: meuNome, codigo: p.codigo, gerenciamento: p.gerenciamento };
  const nomeEtapaPorId = new Map(etapas.filter((e) => e.etapa_id).map((e) => [e.etapa_id as number, e.nome]));
  const emails = ((emailsData ?? []) as EmailModelo[])
    .filter((m) => !m.condicao || m.condicao === p.gerenciamento)
    .map((m) => ({ id: m.id, etapa_id: m.etapa_id, titulo: m.titulo, para: m.para, assunto: preencherModelo(m.assunto ?? "", vars), corpo: preencherModelo(m.corpo, vars), etapa: m.etapa_id ? nomeEtapaPorId.get(m.etapa_id) ?? null : null }));
  const emailsAtual = atual ? emails.filter((m) => m.etapa_id === atual.etapa_id) : [];
  const comentarios = eventos.filter((e) => e.tipo === "comentario");
  const anexos = (anexosData ?? []) as Anexo[];
  const anexosAtual = atual ? anexos.filter((a) => a.processo_etapa_id === atual.id) : [];
  const gruposAnexos: GrupoAnexos[] = [
    ...(atual ? [{ chave: atual.id, titulo: `${atual.ordem}. ${nomeCurto(atual.nome)}`, sub: "Etapa atual", destaque: true,
      anexos: anexosAtual, destino: { processo_id: p.id, processo_etapa_id: atual.id } }] : []),
    { chave: "geral", titulo: "Arquivos do cliente / gerais", sub: "Documentos do processo que não são de uma etapa específica",
      anexos: anexos.filter((a) => !a.processo_etapa_id), destino: { processo_id: p.id } },
    ...etapas.filter((e) => e.id !== atual?.id && (e.status !== "pendente" || anexos.some((a) => a.processo_etapa_id === e.id))).map((e) => ({
      chave: e.id, titulo: `${e.ordem}. ${nomeCurto(e.nome)}`, sub: e.status === "concluida" ? "Concluída" : undefined,
      anexos: anexos.filter((a) => a.processo_etapa_id === e.id), destino: { processo_id: p.id, processo_etapa_id: e.id },
    })),
  ];

  const tabHref = (t: string) => `/processos/${id}?tab=${t}`;
  const statusProcesso = p.status === "concluido" ? { tipo: "concluido" as const, texto: "Concluído" }
    : p.status === "pausado" ? { tipo: "sem_prazo" as const, texto: "Pausado" }
    : p.status === "cancelado" ? { tipo: "cancelado" as const, texto: "Cancelado" }
    : { tipo: stAtual, texto: atrasada ? "Em atraso" : "Em andamento" };

  return (
    <div className="space-y-4">
      {/* breadcrumb + cabeçalho */}
      <div>
        <nav className="mb-2 flex items-center gap-1 text-xs text-muted" aria-label="Trilha">
          <Link href="/processos" className="hover:text-ink">Processos</Link><ChevronRight size={12} /><Link href={`/clientes/${p.cliente_id}`} className="hover:text-ink">{p.cliente}</Link><ChevronRight size={12} /><span className="text-ink">{p.codigo}</span>
        </nav>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold tracking-tight"><Link href={`/clientes/${p.cliente_id}`} className="hover:text-primary-2">{p.cliente}</Link></h1>
              <span className="text-xs text-subtle">{p.codigo}</span>
            </div>
            <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
              <PlanoTag plano={p.plano} />
              {p.certificacao && <span className="chip border border-line bg-surface text-muted">Com certificação</span>}
              {p.gerenciamento && <span className="chip border border-line bg-surface text-muted">{GERENCIAMENTO_LABEL[p.gerenciamento]}</span>}
              {!p.gerenciamento && p.status === "ativo" && <span className="chip bg-warn-soft text-warn-ink">Tipo de ordem não definido</span>}
              {p.contato && <span className="text-xs text-muted">· Contato: {p.contato}</span>}
            </div>
          </div>
          <div className="flex items-center gap-2">
            {(p.status === "concluido" ? !!eu?.admin : !!atual && idxAtual > 0 && podeAtual) && (
              <Modal rotulo={<><RotateCcw size={14} /> Voltar etapa</>} titulo="Voltar uma etapa" descricao="A etapa atual volta a ficar pendente e a anterior é reaberta.">
                <form action={retornarProcesso} className="space-y-3">
                  <input type="hidden" name="processo_id" value={p.id} />
                  <div><label className="label">Motivo</label><input name="motivo" className="input" placeholder="Ex.: avancei por engano" /></div>
                  <div className="flex justify-end"><SubmitButton>Voltar etapa</SubmitButton></div>
                </form>
              </Modal>
            )}
            {p.status === "ativo" && podeProc && (
              <Modal rotulo={<><Pause size={14} /> Pausar</>} titulo="Pausar processo" descricao="O processo sai do kanban e dos prazos até ser retomado. Fica na aba Pausados.">
                <form action={pausarProcesso} className="space-y-3">
                  <input type="hidden" name="processo_id" value={p.id} />
                  <div><label className="label">Motivo</label><input name="motivo" className="input" placeholder="Ex.: cliente pediu para aguardar" /></div>
                  <div className="flex justify-end"><SubmitButton>Pausar processo</SubmitButton></div>
                </form>
              </Modal>
            )}
            {p.status === "pausado" && podeProc && (
              <form action={pausarProcesso}>
                <input type="hidden" name="processo_id" value={p.id} /><input type="hidden" name="retomar" value="1" />
                <SubmitButton className="btn-primary" pendente="Retomando…"><Play size={14} /> Retomar processo</SubmitButton>
              </form>
            )}
            {p.status === "ativo" && podeProc && (
              <Modal rotulo={<><XCircle size={14} /> Cancelar processo</>} botaoClasse="btn-danger" titulo="Cancelar processo" descricao="O processo sai do kanban e vai para a aba Cancelados. Dá para reativar depois.">
                <form action={cancelarProcesso} className="space-y-3">
                  <input type="hidden" name="processo_id" value={p.id} />
                  <div><label className="label">Motivo</label><input name="motivo" className="input" required /></div>
                  <div className="flex justify-end"><SubmitButton className="btn bg-bad text-white hover:bg-bad-ink">Cancelar processo</SubmitButton></div>
                </form>
              </Modal>
            )}
            <Menu>
              <Link href={tabHref("dados")} className="flex h-8 items-center gap-2 rounded px-2 text-[13px] hover:bg-sunken"><Pencil size={14} /> Editar dados</Link>
              {p.status === "cancelado" && podeProc && (
                <form action={cancelarProcesso}>
                  <input type="hidden" name="processo_id" value={p.id} /><input type="hidden" name="reativar" value="1" />
                  <button className="flex h-8 w-full items-center gap-2 rounded px-2 text-[13px] hover:bg-sunken"><RefreshCcw size={14} /> Reativar processo</button>
                </form>
              )}
              <Link href={tabHref("historico")} className="flex h-8 items-center gap-2 rounded px-2 text-[13px] hover:bg-sunken"><CalendarClock size={14} /> Ver histórico</Link>
            </Menu>
          </div>
        </div>
      </div>

      {p.status === "pausado" && (
        <p className="flex items-center gap-2 rounded-md border border-line bg-sunken px-4 py-2.5 text-[13px] text-muted">
          <Pause size={15} /> Processo <strong className="font-medium text-ink">pausado</strong>: fora do kanban e sem contar prazo. {podeProc ? "Use \"Retomar processo\" para voltar ao fluxo." : ""}
        </p>
      )}

      {/* faixa-resumo */}
      <section className="card grid grid-cols-2 divide-line md:grid-cols-4 md:divide-x">
        <div className="px-4 py-3">
          <p className="text-[11px] font-medium text-muted">Responsável atual</p>
          <div className="mt-1.5">{atual ? <Responsavel ids={atual.responsaveis} label={atual.responsaveis_label} mapa={mapaPerfis} tamanho={26} sub={atual.area} /> : <span className="text-muted">—</span>}</div>
        </div>
        <div className="px-4 py-3">
          <p className="text-[11px] font-medium text-muted">Etapa atual</p>
          {atual ? (
            <>
              <p className="mt-1 text-[13px] font-semibold text-ink">{atual.ordem}. {nomeCurto(atual.nome)}</p>
              <p className="truncate text-xs text-muted" title={proximaAcao ?? undefined}>{atual.situacao ?? (aguardando ? `aguardando cliente${cobrarHoje ? " · cobrar" : ""}` : atrasada ? `${du(Math.abs(diasAtual ?? 0))} acima do prazo` : proximaAcao ? `próximo: ${proximaAcao}` : "em andamento")}</p>
            </>
          ) : <p className="mt-1 text-[13px] text-muted">{p.status === "concluido" ? "Processo finalizado" : "—"}</p>}
        </div>
        <div className="px-4 py-3">
          <p className="text-[11px] font-medium text-muted">{p.status === "concluido" ? "Chegou em" : "Previsão de chegada"}</p>
          <p className="num mt-1 text-[18px] leading-tight font-semibold text-ink">{p.status === "concluido" ? dataBR(p.concluido_em ? paraDataBR(p.concluido_em) : null) : dataBR(previsao)}</p>
          {previsao && <p className="text-xs text-muted">em {du(diasUteisEntre(hoje, previsao, feriados))}</p>}
        </div>
        <div className="px-4 py-3">
          <p className="text-[11px] font-medium text-muted">Status</p>
          <div className="mt-1.5"><StatusBadge tipo={statusProcesso.tipo} texto={statusProcesso.texto} /></div>
          <p className="mt-1 text-xs text-muted">Aberto em {dataBR(p.created_at)}</p>
        </div>
      </section>

      {/* timeline */}
      <section className="card px-4 pt-4 pb-3">
        <ProcessTimeline etapas={etapas} hoje={hoje} responsavel={(e) => {
          const n = e.responsaveis.map((r) => mapaPerfis.get(r)?.nome).filter(Boolean);
          return n.length ? n.join(" / ") : e.responsaveis_label ?? "—";
        }} />
      </section>

      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_320px]">
        <div className="min-w-0 space-y-4">
          {/* etapa atual */}
          {p.status === "ativo" && atual && (
            <section className="card">
              <div className="card-header">
                <div className="min-w-0">
                  <p className="eyebrow">Etapa atual · {atual.area}</p>
                  <h2 className="text-[15px] font-semibold text-ink">{atual.nome}</h2>
                </div>
                <StatusBadge tipo={stAtual} texto={prazoTexto(diasAtual, atrasada, espera)} />
              </div>
              <dl className="grid grid-cols-2 gap-x-4 gap-y-3 border-b border-line px-4 py-3 text-[13px] md:grid-cols-5">
                <div><dt className="text-[11px] text-muted">Responsável</dt><dd className="mt-1"><Responsavel ids={atual.responsaveis} label={atual.responsaveis_label} mapa={mapaPerfis} /></dd></div>
                <div><dt className="text-[11px] text-muted">Prazo</dt><dd className="mt-1">{atual.prazo_dias_uteis != null ? du(atual.prazo_dias_uteis) : "—"}</dd></div>
                <div><dt className="text-[11px] text-muted">Início</dt><dd className="num mt-1">{dataHoraBR(atual.iniciado_em)}</dd></div>
                <div><dt className="text-[11px] text-muted">Previsão</dt><dd className={`num mt-1 ${atrasada ? "font-medium text-bad-ink" : ""}`}>{aguardando ? <span className="text-primary">pausado</span> : dataBR(atual.prazo_em)}</dd></div>
                <div><dt className="text-[11px] text-muted">Checklist</dt><dd className="num mt-1">{checkAtual.length ? `${checkAtual.length - pendentes.length}/${checkAtual.length}` : "—"}</dd></div>
              </dl>

              {aguardando && (
                <div className={`flex flex-wrap items-center gap-3 border-b border-line px-4 py-3 ${cobrarHoje ? "bg-warn-soft/60" : "bg-primary-soft/50"}`}>
                  <Hourglass size={16} className={cobrarHoje ? "text-warn-ink" : "text-primary"} />
                  <div className="min-w-0 flex-1 text-[13px]">
                    <p className="font-medium text-ink">
                      {pendentes[0] ? limparPasso(pendentes[0].titulo).split(" — ")[0] : "Aguardando o cliente"} · prazo pausado
                    </p>
                    <p className="text-xs text-muted">
                      Desde {atual.aguardando_desde ? dataBR(paraDataBR(atual.aguardando_desde)) : "—"} ({du(diasEsperando)})
                      {" · "}{atual.ultima_cobranca ? `última cobrança ${dataBR(paraDataBR(atual.ultima_cobranca))}` : "ainda não cobrado"}
                      {" · "}<span className={cobrarHoje ? "font-medium text-warn-ink" : ""}>{cobrarHoje ? "cobrar o cliente esta semana" : `próxima cobrança ${dataBR(proximaCobranca)}`}</span>
                    </p>
                    <p className="mt-0.5 text-[11.5px] text-subtle">Quando o cliente responder, marque o item no checklist — a etapa ganha {du(pendentes[0]?.prazo_depois ?? 1)} para terminar.</p>
                  </div>
                  {podeAtual && <CobrancaForm peId={atual.id} />}
                </div>
              )}

              {!podeAtual && (
                <p className="flex items-center gap-2 border-b border-line bg-sunken/60 px-4 py-2.5 text-xs text-muted">
                  <Lock size={13} /> Somente leitura: esta etapa é de <strong className="font-medium text-ink">{atual.area}{donoAtual ? ` (${donoAtual})` : ""}</strong>. Você pode ver, comentar e anexar arquivos.
                </p>
              )}

              {/* situação */}
              {podeAtual ? <form action={definirSituacao} className="flex flex-wrap items-center gap-2 border-b border-line px-4 py-3">
                <input type="hidden" name="pe_id" value={atual.id} /><input type="hidden" name="processo_id" value={p.id} />
                <label htmlFor="situacao" className="text-xs font-medium text-muted">Por que está aqui?</label>
                <input id="situacao" name="situacao" defaultValue={atual.situacao ?? ""} className="input h-8 min-w-[220px] flex-1" placeholder="Ex.: aguardando confirmação do fornecedor" />
                <SubmitButton className="btn-ghost">Salvar situação</SubmitButton>
              </form> : atual.situacao ? <p className="border-b border-line px-4 py-2.5 text-[13px]"><span className="text-xs font-medium text-muted">Situação: </span>{atual.situacao}</p> : null}

              {/* ações */}
              <div className="flex flex-wrap items-center gap-2 px-4 py-3">
                {podeAtual && (<>
                <Modal rotulo={<><CircleCheck size={15} /> Concluir etapa e avançar</>} botaoClasse="btn-primary" titulo={`Concluir "${nomeCurto(atual.nome)}"`}
                  descricao={proxima ? `A próxima etapa, ${nomeCurto(proxima.nome)}, começa agora com prazo de ${proxima.prazo_dias_uteis != null ? du(proxima.prazo_dias_uteis) : "—"}.` : "O processo será finalizado."}>
                  <form action={avancarProcesso} className="space-y-3">
                    <input type="hidden" name="processo_id" value={p.id} />
                    {pendentes.length > 0 && (
                      <p className="rounded-md bg-warn-soft px-3 py-2 text-xs text-warn-ink">Ainda {pendentes.length === 1 ? "falta 1 item" : `faltam ${pendentes.length} itens`} do checklist desta etapa.</p>
                    )}
                    <div><label className="label">Observação (opcional)</label><textarea name="obs" rows={3} className="textarea" placeholder="Ex.: booking confirmado, nº 12345" /></div>
                    <div className="flex justify-end"><SubmitButton>Concluir e avançar <ArrowRight size={14} /></SubmitButton></div>
                  </form>
                </Modal>
                <Modal rotulo={<><CalendarClock size={14} /> {atual.prazo_editavel ? "Definir data de chegada" : "Ajustar prazo"}</>} titulo={atual.prazo_editavel ? "Data prevista (ETA)" : "Ajustar prazo da etapa"}>
                  <form action={alterarPrazo} className="space-y-3">
                    <input type="hidden" name="processo_id" value={p.id} /><input type="hidden" name="pe_id" value={atual.id} /><input type="hidden" name="etapa_nome" value={atual.nome} />
                    <div><label className="label">Nova data</label><input type="date" name="prazo_em" defaultValue={atual.prazo_em ?? ""} className="input" /></div>
                    <div className="flex justify-end"><SubmitButton>Salvar prazo</SubmitButton></div>
                  </form>
                </Modal>
                <Modal rotulo="Trocar responsável" titulo="Responsáveis desta etapa">
                  <form action={alterarResponsaveis} className="space-y-3">
                    <input type="hidden" name="processo_id" value={p.id} /><input type="hidden" name="pe_id" value={atual.id} /><input type="hidden" name="etapa_nome" value={atual.nome} />
                    <div className="max-h-72 divide-y divide-line overflow-y-auto rounded-md border border-line">
                      {perfis.map((pf) => (
                        <label key={pf.id} className="flex cursor-pointer items-center gap-2.5 px-3 py-2 text-[13px] hover:bg-sunken">
                          <input type="checkbox" name="responsaveis" value={pf.id} defaultChecked={atual.responsaveis.includes(pf.id)} />
                          <span className="flex-1">{pf.nome ?? pf.email}</span>
                          <span className="text-xs text-muted">{pf.cargo}</span>
                        </label>
                      ))}
                    </div>
                    <div className="flex justify-end"><SubmitButton>Salvar responsáveis</SubmitButton></div>
                  </form>
                </Modal>
                </>)}
                <AnexarBotao destino={{ processo_id: p.id, processo_etapa_id: atual.id }} />
                {anexosAtual.length > 0 && (
                  <Link href={tabHref("anexos")} className="text-xs text-primary-2 hover:underline">{anexosAtual.length} arquivo{anexosAtual.length > 1 ? "s" : ""} nesta etapa</Link>
                )}
              </div>
            </section>
          )}

          {/* abas */}
          <section className="card">
            <div className="px-4 pt-1">
              <Tabs ativo={tab} className="border-b-0" itens={[
                { chave: "checklist", rotulo: "Checklist", href: tabHref("checklist"), contagem: checkAtual.length ? checkAtual.length - pendentes.length : undefined },
                { chave: "emails", rotulo: "E-mails", href: tabHref("emails"), contagem: emailsAtual.length || undefined },
                { chave: "anexos", rotulo: "Anexos", href: tabHref("anexos"), contagem: anexos.length || undefined },
                { chave: "comentarios", rotulo: "Comentários", href: tabHref("comentarios"), contagem: comentarios.length || undefined },
                { chave: "historico", rotulo: "Histórico", href: tabHref("historico") },
                { chave: "dados", rotulo: "Dados", href: tabHref("dados") },
              ]} />
            </div>
            <div className="border-t border-line p-4">
              {tab === "checklist" && (
                <div className="space-y-4">
                  {checkAtual.length > 0 ? (
                    <div>
                      <p className="mb-2 text-xs font-medium text-muted">{atual ? nomeCurto(atual.nome) : ""}</p>
                      <Checklist itens={checkAtual} nomes={nomes} responsaveis={respItens} bloqueados={bloqueados} />
                    </div>
                  ) : <EmptyState compacto titulo="Esta etapa não tem checklist" texto="Itens podem ser configurados em Configurações › Checklists." />}
                  {!p.gerenciamento && p.status === "ativo" && (
                    <p className="rounded-md bg-warn-soft px-3 py-2 text-xs text-warn-ink">
                      Defina o tipo de ordem (NTL ou próprio NLG) na aba <Link href={tabHref("dados")} className="font-medium underline">Dados</Link> para liberar o checklist das etapas pós-fechamento.
                    </p>
                  )}
                  <details className="rounded-md border border-line">
                    <summary className="flex cursor-pointer items-center justify-between px-3 py-2 text-[13px] font-medium">Checklist das outras etapas <ChevronRight size={14} className="text-subtle" /></summary>
                    <div className="divide-y divide-line border-t border-line">
                      {etapas.filter((e) => e.id !== atual?.id).map((e) => {
                        const c = checklist.filter((x) => x.processo_etapa_id === e.id);
                        if (!c.length) return null;
                        const f = c.filter((x) => x.feito).length;
                        return (
                          <div key={e.id} className="px-3 py-2">
                            <p className="flex items-center justify-between text-[12.5px]"><span className="font-medium text-ink">{e.ordem}. {nomeCurto(e.nome)}</span><span className="num text-muted">{f}/{c.length}</span></p>
                            <ul className="mt-1 space-y-0.5">
                              {c.map((x) => <li key={x.id} className={`text-xs ${x.feito ? "text-ok-ink" : "text-muted"}`}>{x.feito ? "✓" : "○"} {limparPasso(x.titulo)}</li>)}
                            </ul>
                          </div>
                        );
                      })}
                    </div>
                  </details>
                </div>
              )}

              {tab === "emails" && (
                <div className="space-y-4">
                  {emailsAtual.length > 0 && (<div><p className="mb-2 text-xs font-medium text-muted">Desta etapa</p><EmailModelos emails={emailsAtual} /></div>)}
                  <div><p className="mb-2 text-xs font-medium text-muted">Todos os modelos (preenchidos com os dados deste processo)</p><EmailModelos emails={emails.filter((m) => !emailsAtual.includes(m))} /></div>
                </div>
              )}

              {tab === "anexos" && (
                <div className="space-y-3">
                  <p className="text-xs text-muted">Arquivos ficam guardados por etapa. Só a equipe vê — o cliente não tem acesso pelo portal. Limite de 50 MB por arquivo.</p>
                  <Anexos grupos={gruposAnexos} autores={nomes} />
                </div>
              )}

              {tab === "comentarios" && (
                <div className="space-y-4">
                  <form action={comentar} className="flex gap-2">
                    <input type="hidden" name="processo_id" value={p.id} />
                    <input name="texto" className="input" placeholder="Escreva um comentário para a equipe…" required />
                    <SubmitButton className="btn-primary">Comentar</SubmitButton>
                  </form>
                  {comentarios.length ? (
                    <ActivityTimeline mostrarProcesso={false} itens={comentarios.map((c) => ({ ...c, autor: c.autor ? mapaPerfis.get(c.autor)?.nome ?? null : null }))} />
                  ) : <EmptyState compacto titulo="Nenhum comentário ainda" />}
                </div>
              )}

              {tab === "historico" && (
                <div className="grid gap-6 2xl:grid-cols-[1.4fr_1fr]">
                  <div className="scroll-x">
                    <table className="table-base min-w-[640px]">
                      <thead><tr><th>Etapa</th><th>Responsável</th><th>Início</th><th>Prazo</th><th>Conclusão</th><th className="text-right">Prev.</th><th className="text-right">Real.</th></tr></thead>
                      <tbody>
                        {etapas.map((e) => {
                          const st = estadoDe(e, hoje);
                          const fim = e.concluido_em ?? (e.status === "em_andamento" ? new Date().toISOString() : null);
                          const real = duracaoUteis(e.iniciado_em, fim, feriados);
                          return (
                            <tr key={e.id} className={e.status === "em_andamento" ? "bg-primary-soft/40" : ""}>
                              <td><span className="num text-subtle">{e.ordem}.</span> <span className={e.status === "pendente" ? "text-muted" : "text-ink"}>{nomeCurto(e.nome)}</span></td>
                              <td className="text-muted">{resp(e)}</td>
                              <td className="num text-muted">{e.iniciado_em ? dataBR(paraDataBR(e.iniciado_em)) : "—"}</td>
                              <td className="num text-muted">{dataBR(e.prazo_em)}</td>
                              <td className="num text-muted">{e.concluido_em ? dataBR(paraDataBR(e.concluido_em)) : "—"}</td>
                              <td className="num text-right text-muted">{e.prazo_dias_uteis ?? "—"}</td>
                              <td className={`num text-right ${st === "concluida_atraso" || st === "atrasada" ? "font-semibold text-bad-ink" : "text-ink"}`}>{real ?? "—"}{e.status === "em_andamento" && real !== null ? "…" : ""}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                  <div>
                    <p className="mb-3 text-xs font-medium text-muted">Registro de atividades</p>
                    <ActivityTimeline mostrarProcesso={false} itens={eventos.map((e) => ({ ...e, autor: e.autor ? mapaPerfis.get(e.autor)?.nome ?? null : null }))} />
                  </div>
                </div>
              )}

              {tab === "dados" && (
                <form action={editarProcesso}><fieldset disabled={!podeProc} className="grid max-w-3xl gap-4 md:grid-cols-2">
                  {!podeProc && <p className="flex items-center gap-2 rounded-md bg-sunken px-3 py-2 text-xs text-muted md:col-span-2"><Lock size={13} /> Só quem é da etapa atual ({atual?.area ?? "—"}) ou um administrador pode alterar os dados.</p>}
                  <input type="hidden" name="processo_id" value={p.id} />
                  <div>
                    <label className="label">Cliente</label>
                    <select name="cliente_id" defaultValue={p.cliente_id} className="input" required>
                      {((clientesData ?? []) as { id: string; nome: string }[]).map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                    </select>
                    <p className="mt-1 text-[11px] text-muted">Para cadastrar ou renomear, use <Link href={`/clientes/${p.cliente_id}`} className="text-primary-2 hover:underline">Clientes</Link>.</p>
                  </div>
                  <div><label className="label">Contato no cliente</label><input name="contato" defaultValue={p.contato ?? ""} className="input" /></div>
                  <div>
                    <label className="label">Plano</label>
                    <select name="plano" defaultValue={p.plano ?? ""} className="input"><option value="">—</option><option>Flex</option><option>Full</option><option>Premium</option></select>
                  </div>
                  <div>
                    <label className="label">Tipo de ordem</label>
                    <select name="gerenciamento" defaultValue={p.gerenciamento ?? ""} className="input">
                      <option value="">Ainda não definido</option><option value="ntl">Gerenciamento NTL</option><option value="proprio">Próprio NLG</option>
                    </select>
                  </div>
                  <div className="md:col-span-2"><label className="label">Descrição / referência</label><textarea name="descricao" defaultValue={p.descricao ?? ""} rows={3} className="textarea" /></div>
                  <label className="flex items-center gap-2 text-[13px]"><input type="checkbox" name="certificacao" defaultChecked={p.certificacao} /> Produto com certificação</label>
                  <p className="text-xs text-muted md:col-span-2">Mudar plano ou certificação recalcula os prazos das etapas não concluídas; mudar o tipo de ordem ajusta o checklist.</p>
                  <div className="md:col-span-2"><SubmitButton>Salvar alterações</SubmitButton></div>
                </fieldset></form>
              )}
            </div>
          </section>
        </div>

        {/* lateral */}
        <aside className="space-y-4">
          <section className="card">
            <div className="card-header"><h2 className="card-title">Informações do processo</h2></div>
            <dl className="divide-y divide-line text-[13px]">
              {[
                ["Cliente", p.cliente], ["Contato", p.contato ?? "—"], ["Código", p.codigo], ["Plano", p.plano ?? "—"],
                ["Certificação", p.certificacao ? "Sim" : "Não"], ["Tipo de ordem", p.gerenciamento ? GERENCIAMENTO_LABEL[p.gerenciamento] : "Não definido"],
                ["Aberto em", dataBR(p.created_at)], ["Descrição", p.descricao ?? "—"],
              ].map(([k, v]) => (
                <div key={k} className="grid grid-cols-[110px_1fr] gap-2 px-4 py-2"><dt className="text-muted">{k}</dt><dd className="text-ink">{v}</dd></div>
              ))}
            </dl>
          </section>

          {proxima && p.status === "ativo" && (
            <section className="card">
              <div className="card-header"><h2 className="card-title">Próxima etapa</h2></div>
              <div className="space-y-2 px-4 py-3 text-[13px]">
                <p className="font-medium text-ink">{proxima.ordem}. {proxima.nome}</p>
                <p className="text-muted">Prazo: {proxima.prazo_dias_uteis != null && proxima.tipo === "tarefa" ? du(proxima.prazo_dias_uteis) : proxima.tipo === "marco" ? "marco" : "—"}</p>
                <Responsavel ids={proxima.responsaveis} label={proxima.responsaveis_label} mapa={mapaPerfis} />
              </div>
            </section>
          )}

          {emailsAtual.length > 0 && (
            <section className="card">
              <div className="card-header"><h2 className="card-title">E-mails desta etapa</h2></div>
              <ul className="divide-y divide-line">
                {emailsAtual.map((m) => (
                  <li key={m.id}><Link href={tabHref("emails")} className="flex items-center justify-between px-4 py-2.5 text-[13px] text-ink hover:bg-sunken">{m.titulo}<ChevronRight size={14} className="text-subtle" /></Link></li>
                ))}
              </ul>
            </section>
          )}

          <section className="card">
            <div className="card-header"><h2 className="card-title">Últimas atividades</h2><Link href={tabHref("historico")} className="text-xs text-primary-2 hover:underline">Ver tudo</Link></div>
            <div className="px-4 py-3"><ActivityTimeline mostrarProcesso={false} itens={eventos.slice(0, 5).map((e) => ({ ...e, autor: e.autor ? mapaPerfis.get(e.autor)?.nome ?? null : null }))} /></div>
          </section>
        </aside>
      </div>
    </div>
  );
}
