import Link from "next/link";
import { ArrowUpRight, ChevronRight, Mail } from "lucide-react";
import { base } from "@/lib/dados";
import type { ChecklistModelo, EmailModelo } from "@/lib/types";
import { metaCurta, preencherModelo } from "@/lib/format";
import { limparPasso, nomeCurto } from "@/lib/status";
import { FORMULARIOS, INPI, REFERENCIA_PRAZOS } from "@/lib/manualConteudo";
import PageHeader from "@/components/ui/PageHeader";
import CopiarTexto from "@/components/CopiarTexto";

export const dynamic = "force-dynamic";

const RECURSOS = [
  { sec: "emails", rotulo: "E-mails" },
  { sec: "saudacao", rotulo: "Saudação a fornecedores" },
  { sec: "formularios", rotulo: "Formulários" },
  { sec: "inpi", rotulo: "Consulta INPI" },
  { sec: "prazos", rotulo: "Tabela de prazos" },
];

export default async function Manual({ searchParams }: { searchParams: Promise<{ sec?: string }> }) {
  const { sec = "fluxo" } = await searchParams;
  const { supabase, user, etapas: todas, mapaPerfis } = await base();
  const etapas = todas.filter((e) => e.ativo);
  const [{ data: itensData }, { data: emailsData }, { data: texto }] = await Promise.all([
    supabase.from("checklist_modelo").select("*").eq("ativo", true).order("ordem"),
    supabase.from("email_modelos").select("*").eq("ativo", true).order("ordem"),
    supabase.from("textos").select("conteudo").eq("chave", "mensagem_saudacao").maybeSingle(),
  ]);
  const itens = (itensData ?? []) as ChecklistModelo[];
  const emails = (emailsData ?? []) as EmailModelo[];
  const meuNome = mapaPerfis.get(user.id)?.nome ?? null;
  const etapaSel = sec.startsWith("etapa-") ? etapas.find((e) => String(e.id) === sec.slice(6)) : undefined;
  const respEtapa = (e: (typeof etapas)[number]) => {
    const n = e.responsaveis_padrao.map((id) => mapaPerfis.get(id)?.nome).filter(Boolean);
    return n.length ? n.join(" / ") : e.responsaveis_label ?? "—";
  };

  const NavLink = ({ href, ativo, children }: { href: string; ativo: boolean; children: React.ReactNode }) => (
    <Link href={href} scroll={false} aria-current={ativo ? "page" : undefined}
      className={`flex h-8 items-center gap-2 rounded-md px-2.5 text-[13px] ${ativo ? "bg-primary-soft font-medium text-primary" : "text-ink hover:bg-sunken"}`}>{children}</Link>
  );

  return (
    <div>
      <PageHeader titulo="Manual" subtitulo="Como cada etapa funciona, o que fazer e quais modelos usar." />
      <div className="grid gap-5 lg:grid-cols-[240px_minmax(0,1fr)]">
        {/* navegação */}
        <nav className="card h-fit p-2 lg:sticky lg:top-[72px]" aria-label="Seções do manual">
          <NavLink href="/manual" ativo={sec === "fluxo"}>Fluxo geral</NavLink>
          <p className="eyebrow mt-3 mb-1 px-2.5">Etapas</p>
          {etapas.map((e) => (
            <NavLink key={e.id} href={`/manual?sec=etapa-${e.id}`} ativo={sec === `etapa-${e.id}`}>
              <span className="num w-5 text-[11px] text-subtle">{String(e.ordem).padStart(2, "0")}</span>
              <span className="truncate">{nomeCurto(e.nome)}</span>
            </NavLink>
          ))}
          <p className="eyebrow mt-3 mb-1 px-2.5">Recursos</p>
          {RECURSOS.map((r) => <NavLink key={r.sec} href={`/manual?sec=${r.sec}`} ativo={sec === r.sec}>{r.rotulo}</NavLink>)}
        </nav>

        {/* conteúdo */}
        <article className="min-w-0">
          {sec === "fluxo" && (
            <div className="space-y-5">
              <section className="card">
                <div className="card-header"><div><h2 className="card-title">Fluxo geral</h2><p className="card-sub">Da apresentação ao cliente até a mercadoria chegar. Prazos em dias úteis.</p></div></div>
                <div className="scroll-x">
                  <table className="table-base min-w-[720px]">
                    <thead><tr><th className="w-12">#</th><th>Etapa</th><th>Área</th><th>Prazo</th><th>Responsável</th><th className="text-right">Passos</th></tr></thead>
                    <tbody>
                      {etapas.map((e) => (
                        <tr key={e.id}>
                          <td className="num text-subtle">{String(e.ordem).padStart(2, "0")}</td>
                          <td><Link href={`/manual?sec=etapa-${e.id}`} className="font-medium text-ink hover:text-primary-2">{e.nome}</Link></td>
                          <td className="text-muted">{e.area}</td>
                          <td className="num">{metaCurta(e)}{e.prazo_editavel ? " · ajustável" : ""}</td>
                          <td>{respEtapa(e)}</td>
                          <td className="num text-right text-muted">{itens.filter((i) => i.etapa_id === e.id).length || "—"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
              <div className="grid gap-5 md:grid-cols-2">
                <section className="card px-4 py-4">
                  <h2 className="card-title">Regras do fluxo</h2>
                  <ul className="mt-2 list-disc space-y-1.5 pl-5 text-[13px] text-muted">
                    <li>Ao concluir uma etapa, a próxima começa automaticamente com prazo e responsável.</li>
                    <li>Prazos em dias úteis: fins de semana e feriados cadastrados não contam.</li>
                    <li>Projeto: Flex 10 · Full 15 · Premium 25 dias. Cotação: 1 dia, 2 com certificação.</li>
                    <li>A Viagem começa com 30 dias e pode ser ajustada pela data de chegada (ETA).</li>
                    <li>Etapa concluída por engano? Use “Voltar etapa” no processo.</li>
                  </ul>
                </section>
                <section className="card px-4 py-4">
                  <h2 className="card-title">Tipo de ordem</h2>
                  <p className="mt-2 text-[13px] text-muted">
                    Depois do fechamento, cada processo é marcado como <strong className="text-ink">Gerenciamento NTL</strong> ou <strong className="text-ink">Próprio NLG</strong>.
                    O checklist das etapas CX, Booking, Viagem e Transporte muda conforme essa escolha — os itens exclusivos aparecem com a etiqueta do tipo.
                  </p>
                </section>
              </div>
            </div>
          )}

          {etapaSel && (() => {
            const passos = itens.filter((i) => i.etapa_id === etapaSel.id);
            const modelos = emails.filter((m) => m.etapa_id === etapaSel.id);
            const proxima = etapas.find((e) => e.ordem > etapaSel.ordem);
            return (
              <div className="space-y-5">
                <section className="card">
                  <div className="px-5 py-4">
                    <p className="eyebrow">{String(etapaSel.ordem).padStart(2, "0")} · {etapaSel.area}</p>
                    <h2 className="mt-0.5 text-lg font-semibold text-ink">{etapaSel.nome}</h2>
                  </div>
                  <dl className="grid grid-cols-2 divide-line border-t border-line md:grid-cols-4 md:divide-x">
                    <div className="px-5 py-3">
                      <dt className="text-[11px] text-muted">Prazo</dt>
                      <dd className="mt-1 text-[13px] text-ink">
                        {etapaSel.prazo_flex != null ? (
                          <span className="block space-y-0.5">
                            <span className="block">Flex <strong className="num">{etapaSel.prazo_flex}</strong> dias</span>
                            <span className="block">Full <strong className="num">{etapaSel.prazo_full}</strong> dias</span>
                            <span className="block">Premium <strong className="num">{etapaSel.prazo_premium}</strong> dias</span>
                          </span>
                        ) : etapaSel.tipo === "tarefa" ? (
                          <>{etapaSel.prazo_dias_uteis} {etapaSel.prazo_dias_uteis === 1 ? "dia útil" : "dias úteis"}{etapaSel.prazo_com_certificacao != null ? ` · ${etapaSel.prazo_com_certificacao} com certificação` : ""}{etapaSel.prazo_editavel ? " · ajustável pela ETA" : ""}</>
                        ) : etapaSel.tipo === "marco" ? "Marco (sem prazo)" : "Etapa final"}
                      </dd>
                    </div>
                    <div className="px-5 py-3"><dt className="text-[11px] text-muted">Responsável</dt><dd className="mt-1 text-[13px] text-ink">{respEtapa(etapaSel)}</dd></div>
                    <div className="px-5 py-3"><dt className="text-[11px] text-muted">Passos</dt><dd className="num mt-1 text-[13px] text-ink">{passos.length || "—"}</dd></div>
                    <div className="px-5 py-3"><dt className="text-[11px] text-muted">Próxima etapa</dt><dd className="mt-1 text-[13px] text-ink">{proxima ? nomeCurto(proxima.nome) : "—"}</dd></div>
                  </dl>
                </section>

                <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_300px]">
                  <section className="card">
                    <div className="card-header"><h3 className="card-title">Checklist operacional</h3><span className="text-xs text-muted">aparece para marcar em cada processo</span></div>
                    {passos.length ? (
                      <ol className="divide-y divide-line">
                        {passos.map((p, i) => (
                          <li key={p.id} className="flex gap-3 px-4 py-3">
                            <span className="num mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-sunken text-[11px] font-semibold text-muted">{i + 1}</span>
                            <div className="min-w-0">
                              <p className="text-[13px] font-medium text-ink">
                                {limparPasso(p.titulo)}
                                {p.condicao && <span className="chip ml-2 bg-sunken text-muted">{p.condicao === "ntl" ? "Gerenciamento NTL" : "Próprio NLG"}</span>}
                              </p>
                              {p.descricao && <p className="mt-1 whitespace-pre-line text-xs leading-relaxed text-muted">{p.descricao}</p>}
                            </div>
                          </li>
                        ))}
                      </ol>
                    ) : <p className="px-4 py-6 text-center text-xs text-muted">Esta etapa não tem checklist.</p>}
                  </section>
                  <aside className="card h-fit">
                    <div className="card-header"><h3 className="card-title">Modelos relacionados</h3></div>
                    {modelos.length ? (
                      <ul className="divide-y divide-line">
                        {modelos.map((m) => (
                          <li key={m.id}>
                            <Link href={`/emails?modelo=${m.id}`} className="flex items-start gap-2.5 px-4 py-2.5 hover:bg-sunken">
                              <Mail size={15} className="mt-0.5 shrink-0 text-subtle" />
                              <span className="min-w-0 flex-1">
                                <span className="block text-[13px] text-ink">{m.titulo}</span>
                                {m.para && <span className="block truncate text-[11px] text-muted">Para: {m.para}</span>}
                              </span>
                              <ChevronRight size={14} className="mt-0.5 text-subtle" />
                            </Link>
                          </li>
                        ))}
                      </ul>
                    ) : <p className="px-4 py-4 text-xs text-muted">Nenhum modelo de e-mail para esta etapa.</p>}
                  </aside>
                </div>
              </div>
            );
          })()}

          {sec === "emails" && (
            <section className="card">
              <div className="card-header"><div><h2 className="card-title">Modelos de e-mail</h2><p className="card-sub">Abra na biblioteca para copiar já preenchido com os dados de um processo.</p></div><Link href="/emails" className="btn-ghost">Abrir biblioteca</Link></div>
              <ul className="divide-y divide-line">
                {emails.map((m) => (
                  <li key={m.id}>
                    <Link href={`/emails?modelo=${m.id}`} className="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-sunken">
                      <span className="text-[13px] text-ink">{m.titulo}</span>
                      <span className="text-xs text-muted">{etapas.find((e) => e.id === m.etapa_id) ? nomeCurto(etapas.find((e) => e.id === m.etapa_id)!.nome) : "—"}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            </section>
          )}

          {sec === "saudacao" && (() => {
            const t = preencherModelo(texto?.conteudo ?? "", { meu_nome: meuNome }).replaceAll("{nome}", meuNome ?? "______");
            return (
              <section className="card px-5 py-4">
                <h2 className="card-title">Mensagem de saudação a fornecedores</h2>
                <p className="card-sub">Já vem com o seu nome. Cole no chat do Alibaba, Made in China ou Global Sources.</p>
                <p className="mt-3 rounded-md border border-line bg-sunken p-4 text-[13px] leading-relaxed text-ink">{t}</p>
                <div className="mt-3"><CopiarTexto texto={t} /></div>
              </section>
            );
          })()}

          {sec === "formularios" && (
            <div className="grid gap-4 md:grid-cols-2">
              {FORMULARIOS.map((f) => (
                <section key={f.titulo} className="card px-4 py-4">
                  <h2 className="card-title">{f.titulo}</h2>
                  {f.onde && <p className="card-sub">{f.onde}</p>}
                  <ul className="mt-2 list-disc space-y-1 pl-5 text-[13px] text-muted">{f.campos.map((c) => <li key={c}>{c}</li>)}</ul>
                </section>
              ))}
            </div>
          )}

          {sec === "inpi" && (
            <section className="card px-5 py-4">
              <h2 className="card-title">Consulta de marca / patente no INPI</h2>
              <p className="mt-2 text-[13px] text-muted">{INPI.texto}</p>
              <ol className="mt-3 list-decimal space-y-1 pl-5 text-[13px] text-ink">{INPI.passos.map((p) => <li key={p}>{p}</li>)}</ol>
              <a href={INPI.url} target="_blank" rel="noreferrer" className="btn-ghost mt-4">Abrir consulta do INPI <ArrowUpRight size={14} /></a>
            </section>
          )}

          {sec === "prazos" && (
            <section className="card overflow-hidden">
              <div className="card-header"><div><h2 className="card-title">Organização das datas por tarefa</h2><p className="card-sub">{REFERENCIA_PRAZOS.aviso}</p></div></div>
              <div className="scroll-x">
                <table className="table-base min-w-[560px]">
                  <thead><tr>{REFERENCIA_PRAZOS.colunas.map((c, i) => <th key={c} className={i ? "text-right" : ""}>{c}</th>)}</tr></thead>
                  <tbody>{REFERENCIA_PRAZOS.linhas.map((l) => <tr key={l[0]}>{l.map((v, i) => <td key={i} className={i ? "num text-right" : ""}>{v}</td>)}</tr>)}</tbody>
                </table>
              </div>
            </section>
          )}
        </article>
      </div>
    </div>
  );
}
