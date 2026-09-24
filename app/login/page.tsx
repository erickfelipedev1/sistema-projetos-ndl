"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const [modo, setModo] = useState<"entrar" | "cadastrar">("entrar");
  const [nome, setNome] = useState("");
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [erro, setErro] = useState<string | null>(null);
  const [aviso, setAviso] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
    setAviso(null);
    setCarregando(true);
    const supabase = createClient();
    if (modo === "entrar") {
      const { error } = await supabase.auth.signInWithPassword({ email, password: senha });
      if (error) setErro("E-mail ou senha inválidos");
      else { router.push("/"); router.refresh(); }
    } else {
      const { data, error } = await supabase.auth.signUp({ email, password: senha, options: { data: { nome } } });
      if (error) setErro(error.message);
      else if (data.session) { router.push("/"); router.refresh(); }
      else setAviso("Conta criada. Confirme pelo link enviado ao seu e-mail e depois entre.");
    }
    setCarregando(false);
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-4">
      <form onSubmit={enviar} className="card w-full max-w-sm space-y-4 p-6">
        <div>
          <h1 className="text-lg font-semibold">Controle de Processos</h1>
          <p className="text-sm text-slate-500">{modo === "entrar" ? "Entre com sua conta" : "Crie sua conta"}</p>
        </div>
        {modo === "cadastrar" && (
          <div>
            <label className="label">Nome</label>
            <input className="input" value={nome} onChange={(e) => setNome(e.target.value)} required />
          </div>
        )}
        <div>
          <label className="label">E-mail</label>
          <input className="input" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </div>
        <div>
          <label className="label">Senha</label>
          <input className="input" type="password" minLength={6} value={senha} onChange={(e) => setSenha(e.target.value)} required />
        </div>
        {erro && <p className="text-sm text-red-600">{erro}</p>}
        {aviso && <p className="text-sm text-emerald-700">{aviso}</p>}
        <button className="btn-primary w-full" disabled={carregando}>
          {carregando ? "Aguarde…" : modo === "entrar" ? "Entrar" : "Criar conta"}
        </button>
        <button type="button" className="w-full text-sm text-indigo-600 hover:underline"
          onClick={() => setModo(modo === "entrar" ? "cadastrar" : "entrar")}>
          {modo === "entrar" ? "Não tem conta? Cadastre-se" : "Já tem conta? Entrar"}
        </button>
      </form>
    </main>
  );
}
