import type { Cliente } from "@/lib/types";
import { salvarCliente } from "@/app/actions";
import SubmitButton from "@/components/ui/SubmitButton";

export default function ClienteForm({ cliente }: { cliente?: Cliente }) {
  return (
    <form action={salvarCliente} className="grid gap-3 sm:grid-cols-2">
      {cliente && <input type="hidden" name="id" value={cliente.id} />}
      <div className="sm:col-span-2"><label className="label" htmlFor="c-nome">Nome da empresa *</label><input id="c-nome" name="nome" required defaultValue={cliente?.nome} className="input" placeholder="Ex.: Empresa ABC Ltda" /></div>
      <div><label className="label" htmlFor="c-cnpj">CNPJ</label><input id="c-cnpj" name="cnpj" defaultValue={cliente?.cnpj ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="c-contato">Contato principal</label><input id="c-contato" name="contato" defaultValue={cliente?.contato ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="c-email">E-mail</label><input id="c-email" name="email" type="email" defaultValue={cliente?.email ?? ""} className="input" /></div>
      <div><label className="label" htmlFor="c-tel">Telefone</label><input id="c-tel" name="telefone" defaultValue={cliente?.telefone ?? ""} className="input" /></div>
      <div className="sm:col-span-2"><label className="label" htmlFor="c-obs">Observações</label><textarea id="c-obs" name="observacoes" rows={3} defaultValue={cliente?.observacoes ?? ""} className="textarea" /></div>
      <div className="flex justify-end sm:col-span-2"><SubmitButton>{cliente ? "Salvar cliente" : "Cadastrar cliente"}</SubmitButton></div>
    </form>
  );
}
