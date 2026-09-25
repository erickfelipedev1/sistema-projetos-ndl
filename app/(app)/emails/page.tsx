import { Suspense } from "react";
import Link from "next/link";
import { Mail, Send } from "lucide-react";
import { base } from "@/lib/dados";
import type { EmailModelo, Processo } from "@/lib/types";
import { preencherModelo } from "@/lib/format";
import { nomeCurto } from "@/lib/status";
import PageHeader from "@/components/ui/PageHeader";
import Tabs from "@/components/ui/Tabs";
import EmptyState from "@/components/ui/EmptyState";
import CopiarTexto from "@/components/CopiarTexto";
import ParamSelect from "@/components/ui/ProcessoSelect";

export const dynamic = "force-dynamic";

const VARIAVEIS = [
  { chave: "{empresa}", desc: "Empresa do cliente" },
  { chave: "{contato}", desc: "Pessoa de contato" },
  { chave: "{plano}", desc: "Flex, Full ou Premium" },
  { chave: "{meu_nome}", desc: "Seu nome (responsável)" },
  { chave: "{x_ntl}", desc: "“X” se for gerenciamento NTL" },
  { chave: "{x_proprio}", desc: "“X” se for próprio NLG" },
];

export default async function Emails({ searchParams }: { searchParams: Promise<{ cat?: string; modelo?: string; processo?: string }> }) {
  const sp = await searchParams;
  const { supabase, user, etapas, mapaPerfis } = await base();
  const [{ data: emailsData }, { data: procData }] = await Promise.all([
    supabase.from("email_modelos").select("*").eq("ativo", true).order("ordem"),
    supabase.from("processos").select("id,codigo,cliente,contato,plano,gerenciamento,status").eq("status", "ativo").order("cliente"),
  ]);
  const modelos = (emailsData ?? []) as EmailModelo[];
  const processos = (procData ?? []) as Pick<Processo, "id" | "codigo" | "cliente" | "contato" | "plano" | "gerenciamento">[];
  const etapaDe = new Map(etapas.map((e) => [e.id, e]));

  const cats = etapas.filter((e) => modelos.some((m) => m.etapa_id === e.id));
  const cat = sp.cat ?? "todos";
  const ordemEtapa = (m: EmailModelo) => (m.etapa_id ? etapaDe.get(m.etapa_id)?.ordem ?? 99 : 99);
  const lista = (cat === "todos" ? modelos : modelos.filter((m) => String(m.etapa_id) === cat)).sort((a, b) => ordemEtapa(a) - ordemEtapa(b) || a.ordem - b.ordem);
  const sel = modelos.find((m) => String(m.id) === sp.modelo) ?? lista[0];
  const proc = processos.find((p) => p.id === sp.processo);
  const vars = { empresa: proc?.cliente, contato: proc?.contato, plano: proc?.plano, meu_nome: mapaPerfis.get(user.id)?.nome, codigo: proc?.codigo, gerenciamento: proc?.gerenciamento };
  const assunto = sel ? preencherModelo(sel.assunto ?? "", vars) : "";
  const corpo = sel ? preencherModelo(sel.corpo, vars) : "";
  const href = (extra: Record<string, string | undefined>) => {
    const u = new URLSearchParams();
    for (const [k, v] of Object.entries({ cat: sp.cat, processo: sp.processo, modelo: sp.modelo, ...extra })) if (v) u.set(k, v);
    return `/emails?${u.toString()}`;
  };

  return (
    <div>
      <PageHeader titulo="E-mails" subtitulo="Biblioteca de modelos. Escolha um processo para preencher os dados automaticamente." />
      <Tabs ativo={cat} className="mb-4 overflow-x-auto" itens={[
        { chave: "todos", rotulo: "Todos", href: href({ cat: undefined, modelo: undefined }), contagem: modelos.length },
        ...cats.map((e) => ({ chave: String(e.id), rotulo: e.area === "Projetos" && e.nome.startsWith("Projeto") ? "Projeto" : nomeCurto(e.nome), href: href({ cat: String(e.id), modelo: undefined }), contagem: modelos.filter((m) => m.etapa_id === e.id).length })),
      ]} />

      <div className="grid gap-4 xl:grid-cols-[320px_minmax(0,1fr)_260px] lg:grid-cols-[300px_minmax(0,1fr)]">
        {/* lista */}
        <section className="card h-fit overflow-hidden">
          <ul className="divide-y divide-line">
            {lista.map((m) => {
              const on = sel?.id === m.id;
              const et = m.etapa_id ? etapaDe.get(m.etapa_id) : undefined;
              return (
                <li key={m.id}>
                  <Link href={href({ modelo: String(m.id) })} scroll={false} aria-current={on ? "true" : undefined}
                    className={`relative flex gap-2.5 px-4 py-3 ${on ? "bg-primary-soft" : "hover:bg-sunken"}`}>
                    {on && <span className="absolute inset-y-0 left-0 w-0.5 bg-primary" />}
                    <Mail size={15} className={`mt-0.5 shrink-0 ${on ? "text-primary" : "text-subtle"}`} />
                    <span className="min-w-0 flex-1">
                      <span className={`block text-[13px] ${on ? "font-semibold text-primary" : "font-medium text-ink"}`}>{m.titulo}</span>
                      <span className="mt-0.5 block truncate text-[11.5px] text-muted">{m.assunto}</span>
                    </span>
                    {et && <span className="chip h-fit shrink-0 bg-sunken text-muted">{nomeCurto(et.nome)}</span>}
                  </Link>
                </li>
              );
            })}
          </ul>
          {!lista.length && <EmptyState compacto titulo="Nenhum modelo nesta categoria" />}
        </section>

        {/* visualização */}
        <section className="card min-w-0">
          {sel ? (
            <>
              <div className="card-header flex-wrap">
                <div className="min-w-0">
                  <h2 className="text-[15px] font-semibold text-ink">{sel.titulo}</h2>
                  <p className="card-sub">{sel.etapa_id ? `${etapaDe.get(sel.etapa_id)?.area} · ${nomeCurto(etapaDe.get(sel.etapa_id)?.nome ?? "")}` : "Geral"}{sel.condicao ? ` · só ${sel.condicao === "ntl" ? "gerenciamento NTL" : "próprio NLG"}` : ""}</p>
                </div>
                <div className="w-full sm:w-64">
                  <Suspense><ParamSelect nome="processo" valor={sp.processo ?? ""} vazio="Preencher com um processo…"
                    opcoes={processos.map((p) => ({ valor: p.id, rotulo: `${p.cliente} · ${p.codigo}` }))} className="input h-8" /></Suspense>
                </div>
              </div>
              <dl className="divide-y divide-line border-b border-line text-[13px]">
                <div className="grid grid-cols-[90px_1fr] gap-2 px-4 py-2.5"><dt className="text-muted">Para</dt><dd className="text-ink">{sel.para ?? "—"}</dd></div>
                <div className="grid grid-cols-[90px_1fr] items-center gap-2 px-4 py-2.5">
                  <dt className="text-muted">Assunto</dt>
                  <dd className="flex items-center justify-between gap-2"><span className="font-medium text-ink">{assunto || "—"}</span>{assunto && <CopiarTexto texto={assunto} rotulo="Copiar" className="btn-quiet h-7 shrink-0 text-xs" />}</dd>
                </div>
              </dl>
              <div className="px-4 py-4">
                <pre className="max-h-[520px] overflow-y-auto rounded-md border border-line bg-sunken p-4 font-sans text-[13px] leading-relaxed whitespace-pre-wrap text-ink">{corpo}</pre>
                {!proc && <p className="mt-2 text-xs text-muted">Sem processo selecionado: os campos aparecem como XXX.</p>}
                <div className="mt-3 flex flex-wrap gap-2">
                  <CopiarTexto texto={corpo} rotulo="Copiar texto" />
                  {sel.para?.includes("@") && (
                    <a className="btn-primary" href={`mailto:${sel.para.replace(/\s/g, "")}?subject=${encodeURIComponent(assunto)}&body=${encodeURIComponent(corpo)}`}><Send size={14} /> Abrir no e-mail</a>
                  )}
                  {proc && <Link href={`/processos/${proc.id}?tab=emails`} className="btn-quiet">Ver processo</Link>}
                </div>
              </div>
            </>
          ) : <EmptyState titulo="Selecione um modelo" />}
        </section>

        {/* variáveis */}
        <aside className="card h-fit lg:col-span-2 xl:col-span-1">
          <div className="card-header"><h3 className="card-title">Variáveis</h3></div>
          <ul className="divide-y divide-line">
            {VARIAVEIS.map((v) => {
              const val = { "{empresa}": vars.empresa, "{contato}": vars.contato, "{plano}": vars.plano, "{meu_nome}": vars.meu_nome, "{x_ntl}": proc ? (proc.gerenciamento === "ntl" ? "X" : "—") : null, "{x_proprio}": proc ? (proc.gerenciamento === "proprio" ? "X" : "—") : null }[v.chave];
              return (
                <li key={v.chave} className="px-4 py-2">
                  <p className="flex items-center justify-between gap-2"><code className="text-[12px] text-primary-2">{v.chave}</code><span className="truncate text-[12px] text-ink">{val ?? <span className="text-subtle">—</span>}</span></p>
                  <p className="text-[11px] text-muted">{v.desc}</p>
                </li>
              );
            })}
          </ul>
          <p className="border-t border-line px-4 py-2.5 text-[11px] text-muted">Edite os textos em <Link href="/configuracoes?grupo=operacao&sec=emails" className="text-primary-2 hover:underline">Configurações › Modelos de e-mail</Link>.</p>
        </aside>
      </div>
    </div>
  );
}
