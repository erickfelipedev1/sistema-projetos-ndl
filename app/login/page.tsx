"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { emailDoLogin } from "@/lib/login";
import { criarMinhaConta } from "@/app/contas";

export default function LoginPage() {
  const router = useRouter();
  const [modo, setModo] = useState<"entrar" | "criar">("entrar");
  const [usuario, setUsuario] = useState("");
  const [senha, setSenha] = useState("");
  const [nome, setNome] = useState("");
  const [cargo, setCargo] = useState("");
  const [cargos, setCargos] = useState<string[]>([]);
  const [criada, setCriada] = useState<{ usuario: string; senha: string } | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  useEffect(() => {
    if (modo !== "criar" || cargos.length) return;
    createClient().rpc("cargos_disponiveis").then(({ data }) => {
      const lista = ((data ?? []) as { cargo: string }[]).map((c) => c.cargo);
      setCargos([...lista, "Gestão"]);
    });
  }, [modo, cargos.length]);

  async function entrar(login: string, pass: string) {
    const { error } = await createClient().auth.signInWithPassword({ email: emailDoLogin(login), password: pass });
    if (error) return false;
    router.push("/");
    router.refresh();
    return true;
  }

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setErro(null);
    setCarregando(true);
    try {
      if (modo === "entrar") {
        if (!(await entrar(usuario, senha))) setErro("Usuário ou senha inválidos");
      } else {
        const r = await criarMinhaConta(nome, cargo);
        if (!r.ok) setErro(r.erro);
        else setCriada({ usuario: r.usuario, senha: r.senha });
      }
    } catch (e) {
      setErro("Não foi possível concluir. Tente de novo em instantes.");
      console.error(e);
    } finally {
      setCarregando(false);
    }
  }

  return (
    <main className="grid min-h-screen lg:grid-cols-[1fr_minmax(420px,520px)]">
      <section className="hidden flex-col justify-between bg-[#10304f] p-10 text-white lg:flex">
        <div className="flex items-center gap-2.5">
          <span className="flex h-8 w-8 items-center justify-center rounded bg-white text-[11px] font-bold text-[#10304f]">NDL</span>
          <span className="text-sm font-semibold">NDL Projetos</span>
        </div>
        <div className="max-w-md">
          <h1 className="text-[28px] leading-tight font-semibold">Central de operações dos processos de importação.</h1>
          <p className="mt-3 text-sm text-white/65">Da apresentação ao cliente até a mercadoria chegar: prazos, responsáveis, checklists e gargalos em um só lugar.</p>
          <ol className="mt-8 grid grid-cols-6 gap-1.5" aria-hidden>
            {["CS", "Projetos", "Agenc.", "CX", "Viagem", "Chegou"].map((t, i) => (
              <li key={t} className="text-center">
                <span className={`mx-auto flex h-7 w-7 items-center justify-center rounded-full border text-[11px] font-semibold ${i < 3 ? "border-white bg-white text-[#10304f]" : i === 3 ? "border-white text-white" : "border-white/30 text-white/50"}`}>{i + 1}</span>
                <span className="mt-1.5 block text-[10.5px] text-white/60">{t}</span>
              </li>
            ))}
          </ol>
        </div>
        <p className="text-xs text-white/40">Grupo Now · Now Digital Lab</p>
      </section>

      <section className="flex items-center justify-center bg-canvas p-6">
        <div className="w-full max-w-sm">
          {criada ? (
            <div className="card space-y-4 p-6">
              <h2 className="text-lg font-semibold">Conta criada</h2>
              <dl className="rounded-md border border-line bg-sunken px-4 py-3 text-[13px]">
                <div className="flex justify-between"><dt className="text-muted">Usuário</dt><dd className="font-semibold">{criada.usuario}</dd></div>
                <div className="mt-1 flex justify-between"><dt className="text-muted">Senha inicial</dt><dd className="font-semibold">{criada.senha}</dd></div>
              </dl>
              <p className="text-xs text-muted">No primeiro acesso você vai escolher uma senha nova.</p>
              <button className="btn-primary h-9 w-full" disabled={carregando}
                onClick={async () => { setCarregando(true); if (!(await entrar(criada.usuario, criada.senha))) setErro("Não foi possível entrar"); setCarregando(false); }}>
                Entrar agora
              </button>
              {erro && <p className="text-[13px] text-bad-ink">{erro}</p>}
            </div>
          ) : (
            <form onSubmit={enviar} className="card space-y-4 p-6">
              <div>
                <h2 className="text-lg font-semibold">{modo === "entrar" ? "Entrar" : "Primeiro acesso"}</h2>
                <p className="text-[13px] text-muted">{modo === "entrar" ? "Use seu primeiro nome como usuário." : "Crie sua conta com nome e cargo."}</p>
              </div>
              {modo === "entrar" ? (
                <>
                  <div><label className="label" htmlFor="u">Usuário</label><input id="u" className="input h-10" value={usuario} onChange={(e) => setUsuario(e.target.value)} placeholder="Ex.: larissa" autoCapitalize="none" autoComplete="username" required /></div>
                  <div><label className="label" htmlFor="s">Senha</label><input id="s" className="input h-10" type="password" value={senha} onChange={(e) => setSenha(e.target.value)} autoComplete="current-password" required /></div>
                </>
              ) : (
                <>
                  <div>
                    <label className="label" htmlFor="n">Nome</label>
                    <input id="n" className="input h-10" value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Ex.: Larissa Souza" required />
                    <p className="mt-1 text-[11px] text-muted">Usuário = primeiro nome · senha inicial = primeiro nome + 2026.</p>
                  </div>
                  <div>
                    <label className="label" htmlFor="c">Cargo / área</label>
                    <select id="c" className="input h-10" value={cargo} onChange={(e) => setCargo(e.target.value)} required>
                      <option value="" disabled>Selecione…</option>
                      {cargos.map((c) => <option key={c}>{c}</option>)}
                    </select>
                  </div>
                </>
              )}
              {erro && <p className="rounded-md bg-bad-soft px-3 py-2 text-[13px] text-bad-ink">{erro}</p>}
              <button className="btn-primary h-10 w-full" disabled={carregando}>{carregando ? "Aguarde…" : modo === "entrar" ? "Entrar" : "Criar conta"}</button>
              <button type="button" className="w-full text-[13px] text-primary-2 hover:underline" onClick={() => { setErro(null); setModo(modo === "entrar" ? "criar" : "entrar"); }}>
                {modo === "entrar" ? "Primeiro acesso? Criar conta" : "Já tenho conta"}
              </button>
            </form>
          )}
        </div>
      </section>
    </main>
  );
}
