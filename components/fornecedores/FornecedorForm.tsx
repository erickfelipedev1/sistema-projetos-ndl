import type { Fornecedor } from "@/lib/types";
import { salvarFornecedor } from "@/app/actions";
import SubmitButton from "@/components/ui/SubmitButton";

export default function FornecedorForm({ fornecedor }: { fornecedor?: Fornecedor }) {
  return (
    <form action={salvarFornecedor} className="grid gap-3 sm:grid-cols-2">
      {fornecedor && <input type="hidden" name="id" value={fornecedor.id} />}
      <div className="sm:col-span-2"><label className="label" htmlFor="f-nome">Nome do fornecedor *</label><input id="f-nome" name="nome" required defaultValue={fornecedor?.nome} className="input" placeholder="Ex.: Jiangsu Hongmao Sports Co., Ltd" /></div>
      <div><label className="label" htmlFor="f-produto">Produto</label><input id="f-produto" name="produto" defaultValue={fornecedor?.produto ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="f-origem">Origem</label><input id="f-origem" name="origem" defaultValue={fornecedor?.origem ?? ""} className="input" placeholder="Ex.: Canton Fair" /></div>
      <div><label className="label" htmlFor="f-contato">Contato</label><input id="f-contato" name="contato" defaultValue={fornecedor?.contato ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="f-tel">Telefone / WhatsApp</label><input id="f-tel" name="telefone" defaultValue={fornecedor?.telefone ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="f-email">E-mail</label><input id="f-email" name="email" type="email" defaultValue={fornecedor?.email ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="f-site">Site</label><input id="f-site" name="site" defaultValue={fornecedor?.site ?? ""} className="input" /></div>
      <div>
        <label className="label" htmlFor="f-aval">Avaliação</label>
        <select id="f-aval" name="avaliacao" defaultValue={fornecedor?.avaliacao ?? ""} className="input">
          <option value="">—</option>
          {[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      </div>
      <div className="sm:col-span-2"><label className="label" htmlFor="f-obs">Observações</label><textarea id="f-obs" name="observacoes" rows={3} defaultValue={fornecedor?.observacoes ?? ""} className="textarea" /></div>
      <div className="flex justify-end sm:col-span-2"><SubmitButton>{fornecedor ? "Salvar fornecedor" : "Cadastrar fornecedor"}</SubmitButton></div>
    </form>
  );
}
