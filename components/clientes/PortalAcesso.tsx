"use client";

import { useState } from "react";
import { KeyRound, UserPlus } from "lucide-react";
import { criarAcessoPortal, novaSenhaPortal, removerAcessoPortal } from "@/app/contas";
import CopiarTexto from "@/components/CopiarTexto";
import SubmitButton from "@/components/ui/SubmitButton";

type Usuario = { id: string; nome: string | null; usuario: string | null; trocar_senha: boolean };

export default function PortalAcesso({ clienteId, contato, usuarios, site }: { clienteId: string; contato: string | null; usuarios: Usuario[]; site: string }) {
  const [nome, setNome] = useState(contato ?? "");
  const [ocupado, setOcupado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [cred, setCred] = useState<{ usuario: string; senha: string } | null>(null);

  const mensagem = cred
    ? `Olá! Seu acesso ao portal de acompanhamento da NDL:\n\nEndereço: ${site}\nUsuário: ${cred.usuario}\nSenha provisória: ${cred.senha}\n\nNo primeiro acesso você vai escolher uma senha nova.`
    : "";

  async function criar() {
    setOcupado(true); setErro(null);
    const r = await criarAcessoPortal(clienteId, nome);
    setOcupado(false);
    if (r.ok) setCred({ usuario: r.usuario, senha: r.senha }); else setErro(r.erro);
  }
  async function resetar(id: string) {
    setOcupado(true); setErro(null);
    const r = await novaSenhaPortal(id);
    setOcupado(false);
    if (r.ok) setCred({ usuario: r.usuario, senha: r.senha }); else setErro(r.erro);
  }

  return (
    <div className="space-y-3">
      {usuarios.length > 0 && (
        <ul className="divide-y divide-line rounded-md border border-line">
          {usuarios.map((u) => (
            <li key={u.id} className="flex flex-wrap items-center gap-2 px-3 py-2 text-[13px]">
              <div className="min-w-0 flex-1">
                <p className="font-medium text-ink">{u.nome}</p>
                <p className="text-xs text-muted">usuário <span className="font-mono">{u.usuario}</span>{u.trocar_senha ? " · ainda não entrou" : ""}</p>
              </div>
              <button type="button" className="btn-quiet h-7 text-xs" disabled={ocupado} onClick={() => resetar(u.id)}><KeyRound size={13} /> Nova senha</button>
              <form action={removerAcessoPortal}>
                <input type="hidden" name="id" value={u.id} />
                <SubmitButton className="btn-quiet h-7 text-xs text-bad-ink" pendente="Removendo…" confirmar={`Remover o acesso de ${u.nome}? A pessoa não vai mais conseguir entrar.`}>Remover</SubmitButton>
              </form>
            </li>
          ))}
        </ul>
      )}

      <div className="flex flex-wrap items-end gap-2">
        <div className="min-w-[200px] flex-1">
          <label className="label" htmlFor="acesso-nome">Nome da pessoa do cliente</label>
          <input id="acesso-nome" className="input" value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Ex.: Carlos Souza" />
        </div>
        <button type="button" className="btn-primary" disabled={ocupado || nome.trim().length < 2} onClick={criar}><UserPlus size={14} /> {ocupado ? "Criando…" : "Criar acesso"}</button>
      </div>
      {erro && <p className="text-[13px] text-bad-ink">{erro}</p>}

      {cred && (
        <div className="rounded-md border border-ok/40 bg-ok-soft px-3 py-3 text-[13px]">
          <p className="font-medium text-ok-ink">Acesso pronto. Envie estes dados ao cliente — a senha não aparece de novo.</p>
          <dl className="mt-2 grid grid-cols-[90px_1fr] gap-y-1">
            <dt className="text-muted">Endereço</dt><dd className="font-mono text-ink">{site}</dd>
            <dt className="text-muted">Usuário</dt><dd className="font-mono text-ink">{cred.usuario}</dd>
            <dt className="text-muted">Senha</dt><dd className="font-mono text-ink">{cred.senha}</dd>
          </dl>
          <div className="mt-2"><CopiarTexto texto={mensagem} rotulo="Copiar mensagem para o cliente" /></div>
        </div>
      )}
    </div>
  );
}
