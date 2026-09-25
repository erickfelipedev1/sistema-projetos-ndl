import Link from "next/link";
import { CalendarDays } from "lucide-react";
import { base } from "@/lib/dados";
import type { EtapaAtual } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { limparPasso, nomeCurto, prazoTexto, saudacao, statusPrazo } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import Tabs from "@/components/ui/Tabs";
import StatusBadge, { StatusDot } from "@/components/ui/StatusBadge";
import EmptyState from "@/components/ui/EmptyState";
import ProgressBar from "@/components/ui/ProgressBar";
import { PlanoTag } from "@/components/processos/ProcessCard";
import CobrancaForm from "@/components/processos/CobrancaForm";
import SubmitButton from "@/components/ui/SubmitButton";
import { concluirDemanda } from "@/app/actions";
import type { Mensagem } from "@/lib/types";

export const dynamic = "force-dynamic";

export default async function Minhas({ searchParams }: { searchParams: Promise<{ aba?: string }> }) {
  const { aba = "todas" } = await searchParams;
  const { supabase, user, mapaPerfis } = await base();
  const { data } = await supabase.from("v_etapas_atuais").select("*").contains("responsaveis", [user.id]).order("prazo_em", { ascending: true, nullsFirst: false });
  const todas = (data ?? []) as EtapaAtual[];
  const { data: demData } = await supabase.from("mensagens").select("*, processos(codigo,cliente)")
    .eq("demanda_para", user.id).eq("demanda_status", "aberta").order("demanda_prazo", { ascending: true, nullsFirst: false });
  const demandas = (demData ?? []) as (Mensagem & { processos: { codigo: string; cliente: string } | null })[];
  const hojeISO = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
  const eu = mapaPerfis.get(user.id);

  const atrasadas = todas.filter((e) => e.atrasada);
  const hoje = todas.filter((e) => !e.atrasada && e.dias_restantes === 0);
  const aguardando = todas.filter((e) => e.aguardando_cliente);
  const cobrar = aguardando.filter((e) => e.cobrar_hoje);
  const proximas = todas.filter((e) => !e.atrasada && !e.aguardando_cliente && (e.dias_restantes === null || e.dias_restantes > 0));
  const lista = { todas, atrasadas, hoje, proximas, aguardando }[aba as "todas"] ?? todas;
  const dataHoje = new Date().toLocaleDateString("pt-BR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "America/Sao_Paulo" });

  const kpis = [
    { chave: "atrasadas", n: atrasadas.length, rotulo: "Atrasadas", cor: "text-bad-ink", barra: "bg-bad" },
    { chave: "hoje", n: hoje.length, rotulo: "Vencem hoje", cor: "text-warn-ink", barra: "bg-warn" },
    { chave: "proximas", n: proximas.length, rotulo: "Próximas", cor: "text-ink", barra: "bg-primary-2" },
    { chave: "aguardando", n: aguardando.length, rotulo: cobrar.length ? `Aguardando cliente · ${cobrar.length} para cobrar` : "Aguardando cliente", cor: "text-primary", barra: "bg-primary" },
  ];

  return (
    <div className="space-y-5">
      <PageHeader titulo="Minhas tarefas" subtitulo="Veja o que precisa da sua atenção." />

      <section className="card flex flex-wrap items-center justify-between gap-4 px-5 py-4">
        <div className="flex items-center gap-3">
          <span className="flex h-10 w-10 items-center justify-center rounded-md bg-primary-soft text-primary"><CalendarDays size={18} /></span>
          <div>
            <p className="text-[15px] font-semibold text-ink">{saudacao()}, {eu?.nome ?? "tudo bem"}.</p>
            <p className="text-[13px] text-muted">
              {todas.length ? <>Você tem <strong className="text-ink">{todas.length} {todas.length === 1 ? "tarefa pendente" : "tarefas pendentes"}</strong>{atrasadas.length ? <>, sendo <strong className="text-bad-ink">{atrasadas.length} em atraso</strong></> : null}.</> : "Nenhuma etapa com você agora."}
            </p>
          </div>
        </div>
        <p className="text-xs text-muted first-letter:uppercase">{dataHoje}</p>
      </section>

      <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {kpis.map((k) => (
          <Link key={k.chave} href={`/minhas?aba=${k.chave}`} className={`card relative flex items-baseline gap-3 px-4 py-3.5 transition-colors hover:border-line-strong ${aba === k.chave ? "border-primary-2/50" : ""}`}>
            <span className={`absolute inset-y-3 left-0 w-0.5 rounded-r ${k.barra}`} />
            <span className={`num text-[26px] leading-none font-semibold ${k.cor}`}>{k.n}</span>
            <span className="text-[13px] font-medium text-muted">{k.rotulo}</span>
          </Link>
        ))}
      </section>

      {demandas.length > 0 && (
        <section className="card">
          <div className="card-header">
            <div><h2 className="card-title">Demandas para você</h2><p className="text-xs text-muted">Pedidos da equipe e tarefas liberadas no checklist dos processos. Ao concluir, o item do checklist é marcado.</p></div>
            <Link href="/chat?v=demandas" className="text-xs text-primary-2 hover:underline">Ver no chat</Link>
          </div>
          <ul className="divide-y divide-line">
            {demandas.map((d) => {
              const vencida = d.demanda_prazo && d.demanda_prazo < hojeISO;
              const hojeVence = d.demanda_prazo === hojeISO;
              const [primeira, ...resto] = d.texto.split("\n");
              const titulo = d.checklist_id && resto.length ? resto[0] : primeira;
              return (
                <li key={d.id} className="flex flex-wrap items-center gap-3 px-4 py-2.5">
                  <StatusDot tipo={vencida ? "atrasado" : hojeVence ? "atencao" : "em_dia"} />
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-[13px] font-medium text-ink" title={d.texto}>{titulo}</p>
                    <p className="text-xs text-muted">
                      {d.processos ? <Link href={`/processos/${d.processo_id}`} className="text-primary-2 hover:underline">{d.processos.codigo} · {d.processos.cliente}</Link> : "Sem processo"}
                      {" · "}pedido por {mapaPerfis.get(d.autor)?.nome ?? "—"}
                    </p>
                  </div>
                  <span className={`num text-xs ${vencida ? "font-medium text-bad-ink" : hojeVence ? "font-medium text-warn-ink" : "text-muted"}`}>{d.demanda_prazo ? `até ${dataBR(d.demanda_prazo)}` : "sem prazo"}</span>
                  <form action={concluirDemanda}>
                    <input type="hidden" name="id" value={d.id} />
                    <SubmitButton className="btn-ghost h-7 text-xs" pendente="Concluindo…">Concluir</SubmitButton>
                  </form>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {cobrar.length > 0 && (
        <section className="card border-warn/40">
          <div className="card-header">
            <div><h2 className="card-title">Cobrar clientes esta semana</h2><p className="text-xs text-muted">Já faz 7 dias ou mais desde a última cobrança. Cobre o cliente e registre aqui.</p></div>
          </div>
          <ul className="divide-y divide-line">
            {cobrar.map((e) => (
              <li key={e.id} className="flex flex-wrap items-center gap-3 px-4 py-2.5">
                <div className="min-w-0 flex-1">
                  <Link href={`/processos/${e.processo_id}`} className="text-[13px] font-medium text-ink hover:text-primary-2">{e.cliente} <span className="text-xs font-normal text-subtle">{e.codigo}</span></Link>
                  <p className="text-xs text-muted">{e.proxima_acao ? limparPasso(e.proxima_acao).split(" — ")[0] : nomeCurto(e.nome)} · última cobrança {e.ultima_cobranca ? dataBR(e.ultima_cobranca) : "nenhuma"}</p>
                </div>
                <Link href={`/processos/${e.processo_id}?tab=emails`} className="btn-quiet h-7 text-xs">E-mail de cobrança</Link>
                <CobrancaForm peId={e.id} compacto />
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="card overflow-hidden">
        <div className="px-4">
          <Tabs ativo={aba} className="border-b-0" itens={[
            { chave: "todas", rotulo: "Todas", href: "/minhas", contagem: todas.length },
            { chave: "atrasadas", rotulo: "Atrasadas", href: "/minhas?aba=atrasadas", contagem: atrasadas.length },
            { chave: "hoje", rotulo: "Vencem hoje", href: "/minhas?aba=hoje", contagem: hoje.length },
            { chave: "proximas", rotulo: "Próximas", href: "/minhas?aba=proximas", contagem: proximas.length },
            { chave: "aguardando", rotulo: "Aguardando cliente", href: "/minhas?aba=aguardando", contagem: aguardando.length },
          ]} />
        </div>
        {lista.length ? (
          <div className="scroll-x border-t border-line">
            <table className="table-base min-w-[900px]">
              <thead><tr><th>Tarefa</th><th>Empresa</th><th>Plano</th><th>Etapa</th><th>Prazo</th><th>Checklist</th><th className="text-right">Ação</th></tr></thead>
              <tbody>
                {lista.map((e) => {
                  const st = statusPrazo(e.dias_restantes, e.atrasada, e);
                  return (
                    <tr key={e.id}>
                      <td className="max-w-[300px]">
                        <div className="flex items-center gap-2">
                          <StatusDot tipo={st} />
                          <span className="truncate font-medium text-ink" title={e.situacao ?? e.proxima_acao ?? e.nome}>
                            {e.situacao ? e.situacao.charAt(0).toUpperCase() + e.situacao.slice(1) : e.proxima_acao ? limparPasso(e.proxima_acao).split(" — ")[0] : `Concluir ${nomeCurto(e.nome).toLowerCase()}`}
                          </span>
                        </div>
                      </td>
                      <td className="whitespace-nowrap">{e.cliente}<div className="text-[11px] text-subtle">{e.codigo}</div></td>
                      <td><PlanoTag plano={e.plano} /></td>
                      <td className="whitespace-nowrap text-muted"><span className="num text-subtle">{e.ordem}.</span> {nomeCurto(e.nome)}</td>
                      <td className="whitespace-nowrap">
                        <StatusBadge tipo={st} texto={prazoTexto(e.dias_restantes, e.atrasada, e)} />
                        <div className="num mt-0.5 text-[11px] text-subtle">{e.aguardando_cliente ? `cobrar em ${dataBR(e.proxima_cobranca)}` : dataBR(e.prazo_em)}</div>
                      </td>
                      <td className="w-32">{e.checklist_total ? <ProgressBar valor={e.checklist_feitos} total={e.checklist_total} /> : <span className="text-xs text-subtle">—</span>}</td>
                      <td className="text-right"><Link href={`/processos/${e.processo_id}`} className="btn-primary h-7 text-xs">Abrir processo</Link></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="border-t border-line">
            <EmptyState titulo={aba === "todas" ? "Nenhuma etapa com você agora" : "Nada nesta lista"}
              texto={aba === "todas" ? "Se deveria ter, peça para vincularem seu usuário à etapa em Configurações." : undefined} />
          </div>
        )}
      </section>
    </div>
  );
}
