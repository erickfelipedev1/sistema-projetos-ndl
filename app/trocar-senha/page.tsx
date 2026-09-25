"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { trocarSenha } from "@/app/contas";

export default function TrocarSenha() {
  const router = useRouter();
  const [senha, setSenha] = useState("");
  const [confirma, setConfirma] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
    if (senha !== confirma) return setErro("As senhas não conferem");
    setCarregando(true);
    const r = await trocarSenha(senha);
    setCarregando(false);
    if (r.erro) return setErro(r.erro);
    router.push("/");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-canvas p-4">
      <form onSubmit={enviar} className="card w-full max-w-sm space-y-4 p-6">
        <div>
          <h1 className="text-lg font-semibold">Crie sua senha</h1>
          <p className="text-[13px] text-muted">Primeiro acesso: troque a senha inicial por uma só sua.</p>
        </div>
        <div>
          <label className="label">Nova senha</label>
          <input className="input h-10" type="password" minLength={6} value={senha} onChange={(e) => setSenha(e.target.value)} required />
        </div>
        <div>
          <label className="label">Repita a senha</label>
          <input className="input h-10" type="password" minLength={6} value={confirma} onChange={(e) => setConfirma(e.target.value)} required />
        </div>
        {erro && <p className="rounded-md bg-bad-soft px-3 py-2 text-[13px] text-bad-ink">{erro}</p>}
        <button className="btn-primary h-10 w-full" disabled={carregando}>{carregando ? "Salvando…" : "Salvar e entrar"}</button>
      </form>
    </main>
  );
}
