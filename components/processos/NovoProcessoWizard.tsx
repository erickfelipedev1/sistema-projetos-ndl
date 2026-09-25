"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { ArrowLeft, ArrowRight, Building2, Check, Plus } from "lucide-react";
import { addDiasUteis, diasUteisEntre } from "@/lib/diasUteis";
import { dataBR } from "@/lib/format";
import { nomeCurto } from "@/lib/status";
import { criarProcesso } from "@/app/actions";
import SubmitButton from "@/components/ui/SubmitButton";
import Avatar from "@/components/ui/Avatar";

type EtapaW = { id: number; ordem: number; nome: string; area: string; tipo: string; prazo: number | null; flex: number | null; full: number | null; premium: number | null; cert: number | null; responsaveis: string[]; label: string | null };

const PASSOS = ["Cliente", "Configuração", "Responsáveis", "Revisão"];

function prazoDe(e: EtapaW, plano: string, cert: boolean) {
  if (cert && e.cert != null) return e.cert;
  if (plano === "Flex" && e.flex != null) return e.flex;
  if (plano === "Full" && e.full != null) return e.full;
  if (plano === "Premium" && e.premium != null) return e.premium;
  return e.prazo;
}

function Opcao({ nome, valor, atual, onChange, titulo, sub }: { nome: string; valor: string; atual: string; onChange: (v: string) => void; titulo: string; sub?: string }) {
  const on = atual === valor;
  return (
    <label className={`flex cursor-pointer items-start gap-2.5 rounded-md border px-3 py-2.5 transition-colors ${on ? "border-primary-2 bg-primary-soft" : "border-line bg-surface hover:border-line-strong"}`}>
      <input type="radio" name={nome} value={valor} checked={on} onChange={() => onChange(valor)} className="mt-0.5 accent-[var(--color-primary)]" />
      <span><span className={`block text-[13px] font-medium ${on ? "text-primary" : "text-ink"}`}>{titulo}</span>{sub && <span className="block text-[11.5px] text-muted">{sub}</span>}</span>
    </label>
  );
}

type ClienteW = { id: string; nome: string; contato: string | null };

export default function NovoProcessoWizard({ etapas, itens, feriados, hoje, clientes, clienteInicial }: {
  etapas: EtapaW[]; itens: { etapa_id: number; condicao: string | null }[]; feriados: string[]; hoje: string; clientes: ClienteW[]; clienteInicial?: string;
}) {
  const inicial = clientes.find((c) => c.id === clienteInicial);
  const [passo, setPasso] = useState(0);
  const [empresa, setEmpresa] = useState(inicial?.nome ?? "");
  const [contato, setContato] = useState(inicial?.contato ?? "");
  const [sugestoes, setSugestoes] = useState(false);
  const chave = (t: string) => t.trim().toLowerCase();
  const clienteSel = clientes.find((c) => chave(c.nome) === chave(empresa));
  const filtrados = clientes.filter((c) => !empresa.trim() || c.nome.toLowerCase().includes(chave(empresa))).slice(0, 8);
  const escolher = (c: ClienteW) => { setEmpresa(c.nome); if (!contato && c.contato) setContato(c.contato); setSugestoes(false); };
  const [descricao, setDescricao] = useState("");
  const [plano, setPlano] = useState("Full");
  const [cert, setCert] = useState("nao");
  const [ger, setGer] = useState("");
  const [erro, setErro] = useState<string | null>(null);

  const fer = useMemo(() => new Set(feriados), [feriados]);
  const calc = useMemo(() => {
    let data = hoje;
    const linhas = etapas.filter((e) => e.tipo !== "final").map((e) => {
      const p = prazoDe(e, plano, cert === "sim") ?? 0;
      data = addDiasUteis(data, p, fer);
      return { ...e, p, ate: data };
    });
    const tarefas = itens.filter((i) => etapas.some((e) => e.id === i.etapa_id) && (!i.condicao || i.condicao === ger)).length;
    return { linhas, previsao: data, total: diasUteisEntre(hoje, data, fer), tarefas };
  }, [etapas, plano, cert, ger, itens, hoje, fer]);

  const porArea = useMemo(() => {
    const m = new Map<string, { pessoas: string[]; etapas: string[] }>();
    for (const e of etapas.filter((x) => x.tipo === "tarefa")) {
      const cur = m.get(e.area) ?? { pessoas: [], etapas: [] };
      const nomes = e.responsaveis.length ? e.responsaveis : e.label ? [e.label] : [];
      for (const n of nomes) if (!cur.pessoas.includes(n)) cur.pessoas.push(n);
      cur.etapas.push(nomeCurto(e.nome));
      m.set(e.area, cur);
    }
    return [...m.entries()];
  }, [etapas]);

  const avancar = () => {
    if (passo === 0 && !empresa.trim()) return setErro("Informe o cliente");
    setErro(null);
    setPasso((p) => Math.min(3, p + 1));
  };

  return (
    <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_340px]">
      <div className="card">
        {/* stepper */}
        <ol className="flex items-center gap-2 border-b border-line px-5 py-4">
          {PASSOS.map((n, i) => (
            <li key={n} className="flex flex-1 items-center gap-2">
              <button type="button" onClick={() => i < passo && setPasso(i)} disabled={i > passo}
                className={`num flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold ${i < passo ? "bg-ok text-white" : i === passo ? "bg-primary text-white" : "border border-line-strong text-subtle"}`}>
                {i < passo ? <Check size={12} strokeWidth={3} /> : i + 1}
              </button>
              <span className={`text-[13px] ${i === passo ? "font-semibold text-ink" : "text-muted"}`}>{n}</span>
              {i < PASSOS.length - 1 && <span className={`mx-2 hidden h-px flex-1 sm:block ${i < passo ? "bg-ok" : "bg-line"}`} />}
            </li>
          ))}
        </ol>

        <form action={criarProcesso} className="px-5 py-5">
          <input type="hidden" name="cliente" value={empresa} />
          <input type="hidden" name="cliente_id" value={clienteSel?.id ?? ""} />
          <input type="hidden" name="contato" value={contato} />
          <input type="hidden" name="descricao" value={descricao} />
          <input type="hidden" name="plano" value={plano} />
          {cert === "sim" && <input type="hidden" name="certificacao" value="on" />}
          <input type="hidden" name="gerenciamento" value={ger} />

          {passo === 0 && (
            <div className="grid max-w-2xl gap-4 sm:grid-cols-2">
              <div className="sm:col-span-2"><h2 className="text-[15px] font-semibold">Cliente</h2><p className="text-xs text-muted">Quem é o cliente deste processo.</p></div>
              <div className="relative">
                <label className="label" htmlFor="empresa">Cliente (empresa) *</label>
                <input id="empresa" className="input" value={empresa} autoComplete="off" autoFocus placeholder="Buscar cliente ou digitar um novo"
                  role="combobox" aria-expanded={sugestoes} aria-controls="lista-clientes"
                  onChange={(e) => { setEmpresa(e.target.value); setSugestoes(true); }}
                  onFocus={() => setSugestoes(true)} onBlur={() => setTimeout(() => setSugestoes(false), 150)} />
                {sugestoes && filtrados.length > 0 && !clienteSel && (
                  <ul id="lista-clientes" role="listbox" className="absolute z-20 mt-1 max-h-60 w-full overflow-y-auto rounded-md border border-line bg-surface py-1 shadow-[var(--shadow-pop)]">
                    {filtrados.map((c) => (
                      <li key={c.id} role="option" aria-selected={false}>
                        <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => escolher(c)}
                          className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-[13px] hover:bg-sunken">
                          <Building2 size={14} className="text-subtle" /><span className="flex-1 truncate">{c.nome}</span>
                          {c.contato && <span className="truncate text-xs text-subtle">{c.contato}</span>}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                <p className="mt-1 text-[11.5px]">
                  {!empresa.trim() ? <span className="text-muted">Todo processo pertence a um cliente.</span>
                    : clienteSel ? <span className="inline-flex items-center gap-1 text-ok-ink"><Check size={12} /> Cliente cadastrado</span>
                    : <span className="inline-flex items-center gap-1 text-primary-2"><Plus size={12} /> Novo cliente — será cadastrado ao criar</span>}
                </p>
              </div>
              <div><label className="label" htmlFor="contato">Contato no cliente</label><input id="contato" className="input" value={contato} onChange={(e) => setContato(e.target.value)} placeholder="Nome da pessoa" /></div>
              <div className="sm:col-span-2"><label className="label" htmlFor="desc">Descrição / referência</label><textarea id="desc" rows={3} className="textarea" value={descricao} onChange={(e) => setDescricao(e.target.value)} placeholder="Ex.: container 40HC, origem Xangai" /></div>
            </div>
          )}

          {passo === 1 && (
            <div className="max-w-2xl space-y-5">
              <div><h2 className="text-[15px] font-semibold">Configuração</h2><p className="text-xs text-muted">Define os prazos e o checklist do processo.</p></div>
              <fieldset>
                <legend className="label">Plano</legend>
                <div className="grid gap-2 sm:grid-cols-3">
                  {etapas.some((e) => e.flex != null) ? ["Flex", "Full", "Premium"].map((p) => {
                    const e = etapas.find((x) => x.flex != null)!;
                    return <Opcao key={p} nome="plano_r" valor={p} atual={plano} onChange={setPlano} titulo={p} sub={`Projeto em ${prazoDe(e, p, false)} dias úteis`} />;
                  }) : ["Flex", "Full", "Premium"].map((p) => <Opcao key={p} nome="plano_r" valor={p} atual={plano} onChange={setPlano} titulo={p} />)}
                </div>
              </fieldset>
              <fieldset>
                <legend className="label">Certificação</legend>
                <div className="grid gap-2 sm:grid-cols-2">
                  <Opcao nome="cert_r" valor="nao" atual={cert} onChange={setCert} titulo="Não" sub="Cotação de frete internacional em 1 dia útil" />
                  <Opcao nome="cert_r" valor="sim" atual={cert} onChange={setCert} titulo="Sim" sub="Cotação de frete internacional em 2 dias úteis" />
                </div>
              </fieldset>
              <fieldset>
                <legend className="label">Tipo de ordem</legend>
                <div className="grid gap-2 sm:grid-cols-3">
                  <Opcao nome="ger_r" valor="ntl" atual={ger} onChange={setGer} titulo="Gerenciamento NTL" />
                  <Opcao nome="ger_r" valor="proprio" atual={ger} onChange={setGer} titulo="Próprio NLG" />
                  <Opcao nome="ger_r" valor="" atual={ger} onChange={setGer} titulo="Definir depois" sub="no fechamento" />
                </div>
              </fieldset>
            </div>
          )}

          {passo === 2 && (
            <div className="space-y-4">
              <div><h2 className="text-[15px] font-semibold">Responsáveis</h2><p className="text-xs text-muted">Cada etapa cai automaticamente para estas pessoas quando começar.</p></div>
              <ul className="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
                {porArea.map(([area, v]) => (
                  <li key={area} className="rounded-md border border-line px-3 py-2.5">
                    <p className="eyebrow">{area}</p>
                    <div className="mt-1.5 flex flex-wrap items-center gap-2">
                      {v.pessoas.length ? v.pessoas.map((n) => (
                        <span key={n} className="inline-flex items-center gap-1.5 text-[13px] text-ink"><Avatar nome={n} tamanho={22} />{n}</span>
                      )) : <span className="text-[13px] text-muted">—</span>}
                    </div>
                    <p className="mt-1.5 text-[11px] text-muted">{v.etapas.join(" · ")}</p>
                  </li>
                ))}
              </ul>
              <p className="text-xs text-muted">Para mudar os responsáveis padrão, use <Link href="/configuracoes?grupo=equipe&sec=responsaveis" className="text-primary-2 hover:underline">Configurações › Responsáveis</Link>. Depois de criado, dá para trocar em cada etapa.</p>
            </div>
          )}

          {passo === 3 && (
            <div className="space-y-4">
              <div><h2 className="text-[15px] font-semibold">Revisão</h2><p className="text-xs text-muted">Confira antes de criar. A primeira etapa começa hoje.</p></div>
              <dl className="grid gap-x-6 gap-y-2 rounded-md border border-line px-4 py-3 text-[13px] sm:grid-cols-2">
                {[["Cliente", `${empresa || "—"}${empresa && !clienteSel ? " (novo)" : ""}`], ["Contato", contato || "—"], ["Plano", plano], ["Certificação", cert === "sim" ? "Sim" : "Não"],
                  ["Tipo de ordem", ger === "ntl" ? "Gerenciamento NTL" : ger === "proprio" ? "Próprio NLG" : "Definir depois"], ["Descrição", descricao || "—"]].map(([k, v]) => (
                  <div key={k} className="grid grid-cols-[110px_1fr]"><dt className="text-muted">{k}</dt><dd className="text-ink">{v}</dd></div>
                ))}
              </dl>
              <div className="scroll-x rounded-md border border-line">
                <table className="table-base min-w-[520px]">
                  <thead><tr><th>Etapa</th><th>Responsável</th><th className="text-right">Prazo</th><th className="text-right">Previsto até</th></tr></thead>
                  <tbody>
                    {calc.linhas.map((l) => (
                      <tr key={l.id}>
                        <td><span className="num text-subtle">{l.ordem}.</span> {nomeCurto(l.nome)}</td>
                        <td className="text-muted">{l.responsaveis.join(" / ") || l.label || "—"}</td>
                        <td className="num text-right">{l.tipo === "tarefa" ? `${l.p} d.u.` : "marco"}</td>
                        <td className="num text-right">{dataBR(l.ate)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {erro && <p className="mt-4 text-[13px] text-bad-ink">{erro}</p>}

          <div className="mt-6 flex items-center justify-between border-t border-line pt-4">
            {passo > 0 ? <button type="button" className="btn-ghost" onClick={() => setPasso((p) => p - 1)}><ArrowLeft size={14} /> Voltar</button> : <Link href="/processos" className="btn-quiet">Cancelar</Link>}
            {passo < 3 ? <button type="button" className="btn-primary" onClick={avancar}>Continuar <ArrowRight size={14} /></button>
              : <SubmitButton pendente="Criando…">Criar processo</SubmitButton>}
          </div>
        </form>
      </div>

      {/* resumo */}
      <aside className="card h-fit xl:sticky xl:top-[72px]">
        <div className="card-header"><h2 className="card-title">Resumo do processo</h2></div>
        <dl className="divide-y divide-line text-[13px]">
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Início</dt><dd className="num text-ink">{dataBR(hoje)}</dd></div>
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Previsão de chegada</dt><dd className="num font-semibold text-ink">{dataBR(calc.previsao)}</dd></div>
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Duração prevista</dt><dd className="num text-ink">{calc.total} dias úteis</dd></div>
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Etapas</dt><dd className="num text-ink">{etapas.length}</dd></div>
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Responsáveis</dt><dd className="num text-ink">{new Set(etapas.flatMap((e) => e.responsaveis)).size}</dd></div>
          <div className="flex justify-between px-4 py-2.5"><dt className="text-muted">Tarefas de checklist</dt><dd className="num text-ink">{calc.tarefas}{!ger && <span className="text-subtle"> + pós-fechamento</span>}</dd></div>
        </dl>
        <p className="border-t border-line px-4 py-3 text-[11.5px] text-muted">Previsão com os prazos padrão, em dias úteis. A Viagem pode ser ajustada depois pela data de chegada.</p>
      </aside>
    </div>
  );
}
