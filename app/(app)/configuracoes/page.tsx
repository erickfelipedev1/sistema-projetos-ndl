import Link from "next/link";
import { ChevronRight } from "lucide-react";
import { base } from "@/lib/dados";
import type { ChecklistModelo, EmailModelo, Etapa, Profile } from "@/lib/types";
import { dataBR, metaCurta } from "@/lib/format";
import { nomeCurto, relativo } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import Tabs from "@/components/ui/Tabs";
import SubmitButton from "@/components/ui/SubmitButton";
import { Pessoa } from "@/components/ui/Avatar";
import ActivityTimeline from "@/components/ui/ActivityTimeline";
import {
  alterarMinhaSenha, removerFeriado, salvarEmailModelo, salvarEtapa, salvarFeriado, salvarItemChecklist, salvarMeuPerfil,
  salvarOrdemEtapas, salvarResponsaveisPadrao, salvarTexto,
} from "@/app/actions";
import { adicionarPessoa, criarContasDoFluxo, resetarSenha } from "@/app/contas";

export const dynamic = "force-dynamic";

const GRUPOS = {
  fluxo: { rotulo: "Fluxo", secoes: [["etapas", "Etapas e prazos"], ["ordem", "Ordem das etapas"], ["regras", "Regras automáticas"]] },
  equipe: { rotulo: "Equipe", secoes: [["usuarios", "Usuários"], ["cargos", "Cargos"], ["responsaveis", "Responsáveis"], ["permissoes", "Permissões"]] },
  operacao: { rotulo: "Operação", secoes: [["checklists", "Checklists"], ["emails", "Modelos de e-mail"], ["feriados", "Feriados"], ["saudacao", "Saudação a fornecedores"]] },
  sistema: { rotulo: "Sistema", secoes: [["preferencias", "Preferências"], ["seguranca", "Segurança"], ["historico", "Histórico"]] },
} as const;
type Grupo = keyof typeof GRUPOS;

function Secao({ titulo, descricao, children, acoes }: { titulo: string; descricao?: string; children: React.ReactNode; acoes?: React.ReactNode }) {
  return (
    <section className="card">
      <div className="card-header">
        <div><h2 className="card-title">{titulo}</h2>{descricao && <p className="card-sub">{descricao}</p>}</div>
        {acoes}
      </div>
      {children}
    </section>
  );
}

function PessoasCheck({ nome, perfis, marcados }: { nome: string; perfis: Profile[]; marcados: string[] }) {
  return (
    <div className="grid max-h-48 grid-cols-1 overflow-y-auto rounded-md border border-line sm:grid-cols-2">
      {perfis.map((p) => (
        <label key={p.id} className="flex cursor-pointer items-center gap-2 px-3 py-1.5 text-[13px] hover:bg-sunken">
          <input type="checkbox" name={nome} value={p.id} defaultChecked={marcados.includes(p.id)} />
          <span className="truncate">{p.nome ?? p.email}</span>
          {p.cargo && <span className="ml-auto text-[11px] text-muted">{p.cargo}</span>}
        </label>
      ))}
    </div>
  );
}

export default async function Configuracoes({ searchParams }: { searchParams: Promise<{ grupo?: string; sec?: string }> }) {
  const sp = await searchParams;
  const grupo = (sp.grupo && sp.grupo in GRUPOS ? sp.grupo : "fluxo") as Grupo;
  const secoes = GRUPOS[grupo].secoes as readonly (readonly [string, string])[];
  const sec = secoes.some(([k]) => k === sp.sec) ? sp.sec! : secoes[0][0];
  const { supabase, user, etapas, perfis, mapaPerfis } = await base();
  const eu = mapaPerfis.get(user.id);
  const href = (g: string, s?: string) => `/configuracoes?grupo=${g}${s ? `&sec=${s}` : ""}`;

  return (
    <div>
      <PageHeader titulo="Configurações" subtitulo="Fluxo, equipe e conteúdo operacional do sistema." />
      <Tabs ativo={grupo} className="mb-5" itens={(Object.keys(GRUPOS) as Grupo[]).map((g) => ({ chave: g, rotulo: GRUPOS[g].rotulo, href: href(g) }))} />

      <div className="grid gap-5 lg:grid-cols-[220px_minmax(0,1fr)]">
        <nav className="card h-fit p-2" aria-label={GRUPOS[grupo].rotulo}>
          {secoes.map(([k, r]) => (
            <Link key={k} href={href(grupo, k)} scroll={false} aria-current={sec === k ? "page" : undefined}
              className={`flex h-8 items-center justify-between rounded-md px-2.5 text-[13px] ${sec === k ? "bg-primary-soft font-medium text-primary" : "text-ink hover:bg-sunken"}`}>
              {r}<ChevronRight size={14} className={sec === k ? "text-primary" : "text-subtle"} />
            </Link>
          ))}
        </nav>

        <div className="min-w-0 space-y-5">
          {/* ---------------- FLUXO ---------------- */}
          {sec === "etapas" && (
            <Secao titulo="Etapas e prazos" descricao="Prazos em dias úteis. Mudanças valem para processos criados a partir de agora.">
              <ul className="divide-y divide-line">
                {etapas.map((e) => (
                  <li key={e.id}>
                    <details className="group">
                      <summary className="flex cursor-pointer items-center gap-3 px-4 py-2.5 hover:bg-sunken">
                        <span className="num flex h-6 w-6 shrink-0 items-center justify-center rounded bg-primary text-[11px] font-semibold text-white">{e.ordem}</span>
                        <span className="min-w-0 flex-1">
                          <span className={`block truncate text-[13px] font-medium ${e.ativo ? "text-ink" : "text-subtle line-through"}`}>{e.nome}</span>
                          <span className="block text-[11px] text-muted">{e.area} · {e.responsaveis_label ?? "sem responsável"}</span>
                        </span>
                        <span className="num text-xs text-muted">{e.tipo === "tarefa" ? metaCurta(e) : e.tipo}</span>
                        <ChevronRight size={14} className="text-subtle transition-transform group-open:rotate-90" />
                      </summary>
                      <form action={salvarEtapa} className="grid gap-3 border-t border-line bg-sunken/50 px-4 py-4 md:grid-cols-6">
                        <input type="hidden" name="id" value={e.id} />
                        {e.responsaveis_padrao.map((id) => <input key={id} type="hidden" name="responsaveis_padrao" value={id} />)}
                        <div><label className="label">Ordem</label><input name="ordem" type="number" defaultValue={e.ordem} className="input" required /></div>
                        <div className="md:col-span-2"><label className="label">Área</label><input name="area" defaultValue={e.area} className="input" required /></div>
                        <div className="md:col-span-3"><label className="label">Etapa</label><input name="nome" defaultValue={e.nome} className="input" required /></div>
                        <div>
                          <label className="label">Tipo</label>
                          <select name="tipo" defaultValue={e.tipo} className="input"><option value="tarefa">Tarefa</option><option value="marco">Marco</option><option value="final">Final</option></select>
                        </div>
                        <div><label className="label">Prazo padrão</label><input name="prazo_dias_uteis" type="number" min={0} defaultValue={e.prazo_dias_uteis ?? ""} className="input" /></div>
                        <div><label className="label">Flex</label><input name="prazo_flex" type="number" min={0} defaultValue={e.prazo_flex ?? ""} className="input" /></div>
                        <div><label className="label">Full</label><input name="prazo_full" type="number" min={0} defaultValue={e.prazo_full ?? ""} className="input" /></div>
                        <div><label className="label">Premium</label><input name="prazo_premium" type="number" min={0} defaultValue={e.prazo_premium ?? ""} className="input" /></div>
                        <div><label className="label">Com certificação</label><input name="prazo_com_certificacao" type="number" min={0} defaultValue={e.prazo_com_certificacao ?? ""} className="input" /></div>
                        <div className="md:col-span-3"><label className="label">Responsável (texto exibido)</label><input name="responsaveis_label" defaultValue={e.responsaveis_label ?? ""} className="input" /></div>
                        <div className="flex items-end gap-4 md:col-span-3">
                          <label className="flex items-center gap-1.5 text-[13px]"><input type="checkbox" name="prazo_editavel" defaultChecked={e.prazo_editavel} /> Data definida por processo (ETA)</label>
                          <label className="flex items-center gap-1.5 text-[13px]"><input type="checkbox" name="ativo" defaultChecked={e.ativo} /> Ativa</label>
                        </div>
                        <p className="text-[11px] text-muted md:col-span-6">Prazos por plano e com certificação são opcionais — vazio usa o prazo padrão.</p>
                        <div className="md:col-span-6"><SubmitButton>Salvar etapa</SubmitButton></div>
                      </form>
                    </details>
                  </li>
                ))}
              </ul>
            </Secao>
          )}

          {sec === "ordem" && (
            <Secao titulo="Ordem das etapas" descricao="Define a sequência do fluxo para processos novos.">
              <form action={salvarOrdemEtapas}>
                <ul className="divide-y divide-line">
                  {etapas.map((e) => (
                    <li key={e.id} className="flex items-center gap-3 px-4 py-2">
                      <input name={`ordem_${e.id}`} type="number" defaultValue={e.ordem} className="input h-8 w-16! text-center" aria-label={`Ordem de ${e.nome}`} />
                      <span className="flex-1 text-[13px] text-ink">{e.nome}</span>
                      <span className="text-xs text-muted">{e.area}</span>
                    </li>
                  ))}
                </ul>
                <div className="border-t border-line px-4 py-3"><SubmitButton>Salvar ordem</SubmitButton></div>
              </form>
            </Secao>
          )}

          {sec === "regras" && (
            <Secao titulo="Regras automáticas" descricao="Como o sistema age sozinho (regras fixas do fluxo).">
              <ul className="divide-y divide-line text-[13px]">
                {[
                  ["Avanço de etapa", "Ao concluir uma etapa, a próxima começa na hora, com prazo calculado em dias úteis e os responsáveis padrão da etapa."],
                  ["Dias úteis", "Fins de semana e os feriados cadastrados em Operação › Feriados não contam para prazos."],
                  ["Prazo por plano", "Etapas com prazo Flex/Full/Premium usam o prazo do plano do processo; com certificação usam o prazo específico."],
                  ["Recalcular prazos", "Mudar plano ou certificação de um processo recalcula as etapas ainda não concluídas."],
                  ["Tipo de ordem", "Gerenciamento NTL ou Próprio NLG troca os itens do checklist das etapas pós-fechamento."],
                  ["Etapa final", "Ao concluir a última etapa com prazo, o processo passa para Concluídos."],
                  ["Vínculo de pessoas", "Ao criar uma conta, a pessoa é vinculada às etapas que têm o primeiro nome dela como responsável."],
                ].map(([t, d]) => (
                  <li key={t} className="grid gap-1 px-4 py-3 md:grid-cols-[200px_1fr]"><span className="font-medium text-ink">{t}</span><span className="text-muted">{d}</span></li>
                ))}
              </ul>
            </Secao>
          )}

          {/* ---------------- EQUIPE ---------------- */}
          {sec === "usuarios" && (() => {
            const cargos = [...new Set(etapas.filter((e) => e.tipo !== "final").map((e) => e.area)), "Gestão"];
            return (
              <>
                <Secao titulo="Usuários" descricao="Login = primeiro nome · senha inicial = primeiro nome + 2026. A troca de senha é obrigatória no primeiro acesso."
                  acoes={<form action={criarContasDoFluxo}><SubmitButton className="btn-ghost" confirmar="Criar as contas de todos os responsáveis do fluxo que ainda não têm conta?">Criar contas do fluxo</SubmitButton></form>}>
                  <div className="scroll-x">
                    <table className="table-base min-w-[640px]">
                      <thead><tr><th>Pessoa</th><th>Login</th><th>Etapas</th><th className="text-right">Ações</th></tr></thead>
                      <tbody>
                        {perfis.map((p) => (
                          <tr key={p.id}>
                            <td><Pessoa nome={p.nome ?? p.email ?? "—"} sub={p.cargo ?? "sem cargo"} /></td>
                            <td className="text-muted">{p.usuario ?? p.email}</td>
                            <td className="text-xs text-muted">{etapas.filter((e) => e.responsaveis_padrao.includes(p.id)).map((e) => nomeCurto(e.nome)).join(", ") || "—"}</td>
                            <td className="text-right">
                              {p.usuario && (
                                <form action={resetarSenha} className="inline">
                                  <input type="hidden" name="id" value={p.id} />
                                  <SubmitButton className="btn-quiet h-7 text-xs" confirmar={`Voltar a senha de ${p.nome} para a senha inicial?`}>Resetar senha</SubmitButton>
                                </form>
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </Secao>
                <Secao titulo="Adicionar pessoa">
                  <form action={adicionarPessoa} className="grid gap-3 px-4 py-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                    <div><label className="label">Nome</label><input name="nome" required className="input" placeholder="Ex.: Larissa Souza" /></div>
                    <div>
                      <label className="label">Cargo</label>
                      <select name="cargo" required defaultValue="" className="input"><option value="" disabled>Selecione…</option>{cargos.map((c) => <option key={c}>{c}</option>)}</select>
                    </div>
                    <SubmitButton>Adicionar</SubmitButton>
                  </form>
                </Secao>
              </>
            );
          })()}

          {sec === "cargos" && (() => {
            const cargos = [...new Set([...etapas.filter((e) => e.tipo !== "final").map((e) => e.area), "Gestão"])];
            return (
              <Secao titulo="Cargos" descricao="Os cargos vêm das áreas do fluxo. Para criar um novo, adicione uma etapa com a nova área.">
                <ul className="divide-y divide-line">
                  {cargos.map((c) => {
                    const pessoas = perfis.filter((p) => p.cargo === c);
                    return (
                      <li key={c} className="grid gap-2 px-4 py-3 md:grid-cols-[180px_1fr_auto] md:items-center">
                        <span className="text-[13px] font-medium text-ink">{c}</span>
                        <span className="text-xs text-muted">{etapas.filter((e) => e.area === c).map((e) => nomeCurto(e.nome)).join(" · ") || "—"}</span>
                        <span className="flex flex-wrap gap-2">{pessoas.length ? pessoas.map((p) => <Pessoa key={p.id} nome={p.nome ?? ""} tamanho={20} />) : <span className="text-xs text-subtle">ninguém</span>}</span>
                      </li>
                    );
                  })}
                </ul>
              </Secao>
            );
          })()}

          {sec === "responsaveis" && (
            <Secao titulo="Responsáveis por etapa" descricao="Quem recebe o processo automaticamente quando a etapa começa.">
              <ul className="divide-y divide-line">
                {etapas.filter((e) => e.tipo !== "final").map((e) => (
                  <li key={e.id} className="px-4 py-3">
                    <form action={salvarResponsaveisPadrao} className="grid gap-3 md:grid-cols-[220px_1fr]">
                      <input type="hidden" name="id" value={e.id} />
                      <div>
                        <p className="text-[13px] font-medium text-ink">{e.ordem}. {nomeCurto(e.nome)}</p>
                        <p className="text-[11px] text-muted">{e.area}</p>
                        <input name="responsaveis_label" defaultValue={e.responsaveis_label ?? ""} placeholder="Texto quando sem usuário" className="input mt-2 h-8" />
                      </div>
                      <div className="space-y-2">
                        <PessoasCheck nome="responsaveis_padrao" perfis={perfis} marcados={e.responsaveis_padrao} />
                        <div className="flex flex-wrap items-center gap-3">
                          <label className="flex items-center gap-1.5 text-xs text-muted"><input type="checkbox" name="aplicar" /> Aplicar também aos processos em andamento nesta etapa</label>
                          <SubmitButton className="btn-ghost ml-auto">Salvar</SubmitButton>
                        </div>
                      </div>
                    </form>
                  </li>
                ))}
              </ul>
            </Secao>
          )}

          {sec === "permissoes" && (
            <Secao titulo="Permissões" descricao="Como o acesso funciona hoje.">
              <div className="space-y-3 px-4 py-4 text-[13px] text-muted">
                <p>Todas as pessoas com login ativo têm <strong className="text-ink">acesso completo</strong>: veem todos os processos, avançam etapas, editam dados e configurações.</p>
                <p>O acesso ao banco é protegido por usuário autenticado (Supabase Auth + RLS). Quem não tem conta não vê nada.</p>
                <p>Perfis com permissões diferentes (ex.: somente leitura, gestor) podem ser criados numa próxima versão.</p>
              </div>
            </Secao>
          )}

          {/* ---------------- OPERAÇÃO ---------------- */}
          {sec === "checklists" && (async () => {
            const { data } = await supabase.from("checklist_modelo").select("*").order("ordem");
            const itens = (data ?? []) as ChecklistModelo[];
            return (
              <Secao titulo="Checklists das etapas" descricao="Itens que aparecem para marcar em cada processo. Mudanças valem para processos novos.">
                <ul className="divide-y divide-line">
                  {etapas.filter((e) => e.tipo !== "final").map((e) => {
                    const lista = itens.filter((i) => i.etapa_id === e.id);
                    return (
                      <li key={e.id}>
                        <details className="group">
                          <summary className="flex cursor-pointer items-center justify-between px-4 py-2.5 hover:bg-sunken">
                            <span className="text-[13px] font-medium text-ink">{e.ordem}. {nomeCurto(e.nome)} <span className="font-normal text-muted">· {lista.filter((i) => i.ativo).length} itens</span></span>
                            <ChevronRight size={14} className="text-subtle transition-transform group-open:rotate-90" />
                          </summary>
                          <div className="space-y-2 border-t border-line bg-sunken/50 p-3">
                            {[...lista, null].map((i) => (
                              <form key={i?.id ?? "novo"} action={salvarItemChecklist} className="grid gap-2 rounded-md border border-line bg-surface p-3 md:grid-cols-[64px_1fr_200px]">
                                <input type="hidden" name="id" value={i?.id ?? ""} /><input type="hidden" name="etapa_id" value={e.id} />
                                <input name="ordem" type="number" defaultValue={i?.ordem ?? (lista.at(-1)?.ordem ?? 0) + 10} className="input h-8" required aria-label="Ordem" />
                                <input name="titulo" defaultValue={i?.titulo ?? ""} placeholder="Novo item" className="input h-8" required aria-label="Título" />
                                <select name="condicao" defaultValue={i?.condicao ?? ""} className="input h-8" aria-label="Vale para">
                                  <option value="">Todas as ordens</option><option value="ntl">Só gerenciamento NTL</option><option value="proprio">Só próprio NLG</option>
                                </select>
                                <textarea name="descricao" defaultValue={i?.descricao ?? ""} rows={2} placeholder="Instruções (opcional)" className="textarea md:col-span-3" />
                                <details className="rounded-md border border-line md:col-span-3" open={!!i?.responsaveis?.length}>
                                  <summary className="cursor-pointer px-2.5 py-1.5 text-xs font-medium text-muted">Responsável pelo item (recebe demanda automática no chat)</summary>
                                  <div className="space-y-2 border-t border-line p-2.5">
                                    <PessoasCheck nome="item_responsaveis" perfis={perfis} marcados={i?.responsaveis ?? []} />
                                    <div className="flex flex-wrap items-center gap-3 text-xs">
                                      <label className="flex items-center gap-1.5">Prazo <input name="prazo_item" type="number" min={0} defaultValue={i?.prazo_item ?? ""} className="input h-7 w-14" /> d.u.</label>
                                      <label className="flex items-center gap-1.5">com certificação <input name="prazo_item_cert" type="number" min={0} defaultValue={i?.prazo_item_cert ?? ""} className="input h-7 w-14" /> d.u.</label>
                                      <span className="text-subtle">A demanda é enviada quando o item anterior do checklist é marcado.</span>
                                    </div>
                                  </div>
                                </details>
                                <div className="flex items-center gap-3 md:col-span-3">
                                  <label className="flex items-center gap-1.5 text-xs"><input type="checkbox" name="ativo" defaultChecked={i ? i.ativo : true} /> Ativo</label>
                                  <label className="flex items-center gap-1.5 text-xs" title="Enquanto este item for o próximo, o prazo da etapa fica pausado e o sistema pede cobrança semanal"><input type="checkbox" name="aguarda_cliente" defaultChecked={i?.aguarda_cliente ?? false} /> Espera do cliente (pausa o prazo)</label>
                                  <label className="flex items-center gap-1.5 text-xs">depois da resposta: <input name="prazo_depois" type="number" min={0} defaultValue={i?.prazo_depois ?? 1} className="input h-7 w-14" /> d.u.</label>
                                  <SubmitButton className="btn-ghost h-7 text-xs">{i ? "Salvar" : "Adicionar item"}</SubmitButton>
                                </div>
                              </form>
                            ))}
                          </div>
                        </details>
                      </li>
                    );
                  })}
                </ul>
              </Secao>
            );
          })()}

          {sec === "emails" && (async () => {
            const { data } = await supabase.from("email_modelos").select("*").order("ordem");
            return (
              <Secao titulo="Modelos de e-mail" descricao="Variáveis: {empresa} {contato} {plano} {meu_nome} {codigo} {x_ntl} {x_proprio}">
                <ul className="divide-y divide-line">
                  {((data ?? []) as EmailModelo[]).map((m) => (
                    <li key={m.id}>
                      <details className="group">
                        <summary className="flex cursor-pointer items-center justify-between px-4 py-2.5 hover:bg-sunken">
                          <span className="text-[13px] font-medium text-ink">{m.titulo}<span className="ml-2 font-normal text-muted">{etapas.find((e) => e.id === m.etapa_id) ? `· ${nomeCurto(etapas.find((e) => e.id === m.etapa_id)!.nome)}` : ""}</span></span>
                          <ChevronRight size={14} className="text-subtle transition-transform group-open:rotate-90" />
                        </summary>
                        <form action={salvarEmailModelo} className="space-y-2 border-t border-line bg-sunken/50 px-4 py-3">
                          <input type="hidden" name="id" value={m.id} />
                          <div className="grid gap-2 md:grid-cols-2">
                            <div><label className="label">Título</label><input name="titulo" defaultValue={m.titulo} className="input" required /></div>
                            <div><label className="label">Para</label><input name="para" defaultValue={m.para ?? ""} className="input" /></div>
                          </div>
                          <div><label className="label">Assunto</label><input name="assunto" defaultValue={m.assunto ?? ""} className="input" /></div>
                          <div><label className="label">Texto</label><textarea name="corpo" defaultValue={m.corpo} rows={10} className="textarea font-mono text-xs" required /></div>
                          <div className="flex items-center gap-3">
                            <label className="flex items-center gap-1.5 text-xs"><input type="checkbox" name="ativo" defaultChecked={m.ativo} /> Ativo</label>
                            <SubmitButton className="btn-ghost">Salvar modelo</SubmitButton>
                          </div>
                        </form>
                      </details>
                    </li>
                  ))}
                </ul>
              </Secao>
            );
          })()}

          {sec === "feriados" && (async () => {
            const { data } = await supabase.from("feriados").select("*").order("data");
            return (
              <Secao titulo="Feriados" descricao="Não contam como dia útil no cálculo dos prazos.">
                <form action={salvarFeriado} className="flex flex-wrap gap-2 border-b border-line px-4 py-3">
                  <input type="date" name="data" required className="input w-44!" aria-label="Data" />
                  <input name="descricao" required placeholder="Descrição" className="input min-w-[200px] flex-1" />
                  <SubmitButton className="btn-ghost">Adicionar</SubmitButton>
                </form>
                <ul className="max-h-[520px] divide-y divide-line overflow-y-auto">
                  {((data ?? []) as { data: string; descricao: string }[]).map((f) => (
                    <li key={f.data} className="flex items-center justify-between px-4 py-2 text-[13px]">
                      <span><span className="num inline-block w-24 text-muted">{dataBR(f.data)}</span>{f.descricao}</span>
                      <form action={removerFeriado}><input type="hidden" name="data" value={f.data} /><SubmitButton className="btn-quiet h-7 text-xs text-bad-ink" confirmar={`Remover ${f.descricao}?`}>Remover</SubmitButton></form>
                    </li>
                  ))}
                </ul>
              </Secao>
            );
          })()}

          {sec === "saudacao" && (async () => {
            const { data } = await supabase.from("textos").select("conteudo").eq("chave", "mensagem_saudacao").maybeSingle();
            return (
              <Secao titulo="Saudação a fornecedores" descricao="Use {nome} onde deve entrar o nome de quem está copiando.">
                <form action={salvarTexto} className="space-y-3 px-4 py-4">
                  <input type="hidden" name="chave" value="mensagem_saudacao" />
                  <textarea name="conteudo" rows={6} defaultValue={data?.conteudo ?? ""} className="textarea" />
                  <SubmitButton>Salvar mensagem</SubmitButton>
                </form>
              </Secao>
            );
          })()}

          {/* ---------------- SISTEMA ---------------- */}
          {sec === "preferencias" && (
            <Secao titulo="Meu perfil" descricao="Ao salvar, você é vinculado às etapas que têm seu primeiro nome como responsável.">
              <form action={salvarMeuPerfil} className="grid gap-3 px-4 py-4 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                <div><label className="label">Nome</label><input name="nome" defaultValue={eu?.nome ?? ""} className="input" required /></div>
                <div>
                  <label className="label">Cargo</label>
                  <select name="cargo" defaultValue={eu?.cargo ?? ""} className="input" required>
                    <option value="" disabled>Selecione…</option>
                    {[...new Set([...etapas.filter((e) => e.tipo !== "final").map((e) => e.area), "Gestão"])].map((c) => <option key={c}>{c}</option>)}
                  </select>
                </div>
                <SubmitButton>Salvar</SubmitButton>
              </form>
            </Secao>
          )}

          {sec === "seguranca" && (
            <Secao titulo="Alterar minha senha">
              <form action={alterarMinhaSenha} className="grid max-w-xl gap-3 px-4 py-4 sm:grid-cols-2">
                <div><label className="label">Nova senha</label><input name="senha" type="password" minLength={6} required className="input" /></div>
                <div><label className="label">Repita a senha</label><input name="confirma" type="password" minLength={6} required className="input" /></div>
                <div className="sm:col-span-2"><SubmitButton>Alterar senha</SubmitButton></div>
              </form>
            </Secao>
          )}

          {sec === "historico" && (async () => {
            const { data } = await supabase.from("processo_eventos").select("id,tipo,texto,created_at,autor,processo_id,processos(cliente)").order("created_at", { ascending: false }).limit(60);
            const itens = (data ?? []).map((a: any) => ({ id: a.id, tipo: a.tipo, texto: a.texto, created_at: a.created_at, autor: a.autor ? mapaPerfis.get(a.autor)?.nome ?? null : null, processo_id: a.processo_id, processo: a.processos?.cliente ?? null }));
            return (
              <Secao titulo="Histórico do sistema" descricao={`Últimas ${itens.length} atividades em todos os processos · atualizado ${relativo(new Date().toISOString())}`}>
                <div className="px-4 py-4"><ActivityTimeline itens={itens} /></div>
              </Secao>
            );
          })()}
        </div>
      </div>
    </div>
  );
}
