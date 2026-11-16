import { CheckCircle2, Globe, Mail, Pencil, Phone, Plus, Trash2, UserRound } from "lucide-react";
import type { Anexo, ProcessoFornecedor } from "@/lib/types";
import { dataBR } from "@/lib/format";
import { excluirFornecedorProcesso, salvarFornecedorProcesso } from "@/app/actions";
import Modal from "@/components/ui/Modal";
import SubmitButton from "@/components/ui/SubmitButton";
import EmptyState from "@/components/ui/EmptyState";
import Anexos from "@/components/anexos/Anexos";

type Catalogo = { id: string; nome: string; produto: string | null };

function Form({ processoId, f, catalogo }: { processoId: string; f?: ProcessoFornecedor; catalogo: Catalogo[] }) {
  return (
    <form action={salvarFornecedorProcesso} className="grid gap-3 sm:grid-cols-2">
      <input type="hidden" name="processo_id" value={processoId} />
      {f && <input type="hidden" name="id" value={f.id} />}
      <div className="sm:col-span-2">
        <label className="label" htmlFor={`pf-cat-${f?.id ?? "novo"}`}>Do cadastro de Fornecedores (opcional)</label>
        <select id={`pf-cat-${f?.id ?? "novo"}`} name="fornecedor_id" defaultValue={f?.fornecedor_id ?? ""} className="input">
          <option value="">— Fornecedor novo / não cadastrado —</option>
          {catalogo.map((c) => <option key={c.id} value={c.id}>{c.nome}{c.produto ? ` · ${c.produto}` : ""}</option>)}
        </select>
        <p className="mt-1 text-[11px] text-muted">Escolhendo do cadastro, os campos em branco são preenchidos com os dados de lá.</p>
      </div>
      <div className="sm:col-span-2"><label className="label">Nome da fábrica</label><input name="fabrica" defaultValue={f?.fabrica ?? ""} className="input" placeholder="Ex.: Ningbo Hengda Industrial Co., Ltd" /></div>
      <div><label className="label">Contato (nome)</label><input name="contato_nome" defaultValue={f?.contato_nome ?? ""} className="input" /></div>
      <div><label className="label">Telefone / WhatsApp</label><input name="telefone" defaultValue={f?.telefone ?? ""} className="input" /></div>
      <div><label className="label">E-mail</label><input name="email" type="email" defaultValue={f?.email ?? ""} className="input" /></div>
      <div><label className="label">Site</label><input name="site" defaultValue={f?.site ?? ""} className="input" /></div>
      <div className="sm:col-span-2"><label className="label">Descrição e histórico da negociação</label>
        <textarea name="negociacao" rows={4} defaultValue={f?.negociacao ?? ""} className="textarea" placeholder="Preços, MOQ, prazos, amostras, o que foi combinado em cada contato…" /></div>
      <label className="flex items-center gap-2 text-[13px] sm:col-span-2"><input type="checkbox" name="escolhido" defaultChecked={f?.escolhido} /> Escolhido pelo cliente para seguir</label>
      <div className="sm:col-span-2"><label className="label">Condições e documentação acordadas</label>
        <textarea name="condicoes" rows={3} defaultValue={f?.condicoes ?? ""} className="textarea" placeholder="Incoterm, pagamento (ex.: 30/70), prazo de produção, documentos combinados…" /></div>
      {!f && <label className="flex items-center gap-2 text-[13px] sm:col-span-2"><input type="checkbox" name="salvar_cadastro" /> Salvar também no cadastro geral de Fornecedores (se for novo)</label>}
      <div className="flex justify-end sm:col-span-2"><SubmitButton>{f ? "Salvar fornecedor" : "Adicionar fornecedor"}</SubmitButton></div>
    </form>
  );
}

export default function FornecedoresProcesso({ processoId, fornecedores, anexos, catalogo, autores }: {
  processoId: string; fornecedores: ProcessoFornecedor[]; anexos: Anexo[]; catalogo: Catalogo[]; autores: Record<string, string>;
}) {
  const ordenados = [...fornecedores].sort((a, b) => Number(b.escolhido) - Number(a.escolhido) || a.created_at.localeCompare(b.created_at));
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted">Fornecedores negociados neste projeto: contatos, histórico, documentos e o que o cliente escolheu. Assim qualquer pessoa da equipe consegue dar sequência.</p>
        <Modal rotulo={<><Plus size={14} /> Adicionar fornecedor</>} botaoClasse="btn-primary" titulo="Adicionar fornecedor ao projeto" largura={620}>
          <Form processoId={processoId} catalogo={catalogo} />
        </Modal>
      </div>
      {ordenados.length ? ordenados.map((f) => {
        const docs = anexos.filter((a) => a.processo_fornecedor_id === f.id);
        return (
          <section key={f.id} className={`rounded-md border ${f.escolhido ? "border-ok/60" : "border-line"}`}>
            <header className="flex flex-wrap items-start justify-between gap-2 border-b border-line px-4 py-3">
              <div className="min-w-0">
                <h3 className="flex flex-wrap items-center gap-2 text-[14px] font-semibold text-ink">
                  {f.fabrica}
                  {f.escolhido && <span className="chip bg-ok-soft text-ok-ink"><CheckCircle2 size={12} /> Escolhido pelo cliente</span>}
                  {f.fornecedor_id && <span className="chip border border-line bg-surface text-muted">no cadastro</span>}
                </h3>
                <p className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
                  {f.contato_nome && <span className="inline-flex items-center gap-1"><UserRound size={12} />{f.contato_nome}</span>}
                  {f.telefone && <span className="inline-flex items-center gap-1"><Phone size={12} />{f.telefone}</span>}
                  {f.email && <a href={`mailto:${f.email}`} className="inline-flex items-center gap-1 hover:text-primary-2"><Mail size={12} />{f.email}</a>}
                  {f.site && <a href={/^https?:\/\//.test(f.site) ? f.site : `https://${f.site}`} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 hover:text-primary-2"><Globe size={12} />{f.site}</a>}
                  <span>atualizado em {dataBR(f.updated_at)}</span>
                </p>
              </div>
              <div className="flex items-center gap-1">
                <Modal rotulo={<><Pencil size={13} /> Editar</>} botaoClasse="btn-quiet h-7 text-xs" titulo={`Editar ${f.fabrica}`} largura={620}>
                  <Form processoId={processoId} f={f} catalogo={catalogo} />
                </Modal>
                <form action={excluirFornecedorProcesso}>
                  <input type="hidden" name="id" value={f.id} /><input type="hidden" name="processo_id" value={processoId} />
                  <SubmitButton className="rounded p-1.5 text-subtle hover:bg-bad-soft hover:text-bad-ink" pendente="…" confirmar={`Remover ${f.fabrica} deste projeto? Os arquivos dele continuam na aba Documentos (só para a equipe) e saem do portal do cliente.`}>
                    <Trash2 size={15} aria-label="Remover fornecedor" />
                  </SubmitButton>
                </form>
              </div>
            </header>
            <div className="grid gap-3 px-4 py-3 md:grid-cols-2">
              <div>
                <p className="text-[11px] font-medium text-muted">Negociação</p>
                <p className="mt-1 text-[13px] whitespace-pre-line text-ink">{f.negociacao || <span className="text-subtle">—</span>}</p>
              </div>
              <div>
                <p className="text-[11px] font-medium text-muted">Condições e documentação acordadas</p>
                <p className="mt-1 text-[13px] whitespace-pre-line text-ink">{f.condicoes || <span className="text-subtle">—</span>}</p>
              </div>
            </div>
            <div className="px-4 pb-3">
              <Anexos autores={autores} grupos={[{
                chave: f.id, titulo: "Documentos do fornecedor", sub: "Proforma Invoice, Packing List, datasheets, manuais… O olho libera o arquivo no portal do cliente.",
                anexos: docs, destino: { processo_id: processoId, processo_fornecedor_id: f.id }, compartilhar: true,
              }]} />
            </div>
          </section>
        );
      }) : <EmptyState compacto titulo="Nenhum fornecedor neste projeto" texto="Adicione os fornecedores conforme a negociação avança." />}
    </div>
  );
}
