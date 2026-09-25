"use server";

import { revalidatePath } from "next/cache";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { DOMINIO_LOGIN, normaliza, primeiroNome, senhaPadrao } from "@/lib/login";

type Resultado = { ok: true; usuario: string; senha: string } | { ok: false; erro: string };

async function usuarioLivre(base: string, nome: string) {
  const admin = createAdminClient();
  const partes = nome.trim().split(/\s+/).map(normaliza).filter(Boolean);
  const candidatos = [base, partes.length > 1 ? `${base}.${partes[partes.length - 1]}` : null, `${base}2`, `${base}3`, `${base}4`]
    .filter(Boolean) as string[];
  for (const c of candidatos) {
    const { data } = await admin.from("profiles").select("id").eq("usuario", c).maybeSingle();
    if (!data) return c;
  }
  return `${base}${Date.now() % 1000}`;
}

async function criar(nome: string, cargo: string): Promise<Resultado> {
  nome = nome.trim();
  const base = primeiroNome(nome);
  if (base.length < 2) return { ok: false, erro: "Informe o nome" };
  const usuario = await usuarioLivre(base, nome);
  const senha = senhaPadrao(nome);
  const admin = createAdminClient();
  const { error } = await admin.auth.admin.createUser({
    email: `${usuario}@${DOMINIO_LOGIN}`,
    password: senha,
    email_confirm: true,
    user_metadata: { nome, cargo, usuario, trocar_senha: true },
  });
  if (error) return { ok: false, erro: traduzErro(error.message) };
  return { ok: true, usuario, senha };
}

// Tela de login: "Primeiro acesso"
export async function criarMinhaConta(nome: string, cargo: string): Promise<Resultado> {
  if (!cargo) return { ok: false, erro: "Selecione o cargo" };
  try {
    return await criar(nome, cargo);
  } catch (e) {
    console.error("criarMinhaConta", e);
    return { ok: false, erro: traduzErro(e instanceof Error ? e.message : String(e)) };
  }
}

function traduzErro(msg: string) {
  if (msg.includes("SUPABASE_SERVICE_ROLE_KEY")) return "Configuração pendente no servidor (SUPABASE_SERVICE_ROLE_KEY). Avise o administrador.";
  if (/already.*registered|already exists/i.test(msg)) return "Já existe uma conta com esse usuário.";
  if (/Database error/i.test(msg)) return "Erro no banco ao criar a conta (confira se os SQLs 003 e 004 foram rodados).";
  return msg;
}

// ações administrativas: só quem é da equipe (clientes do portal não podem)
async function exigirAdmin() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("is_admin");
  if (data !== true) throw new Error("Só um administrador pode fazer isso");
}

async function exigirLogado() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("Não autenticado");
  const { data: perfil } = await supabase.from("profiles").select("tipo").eq("id", user.id).maybeSingle();
  if (perfil?.tipo !== "equipe") throw new Error("Sem permissão");
}

// Configurações: adicionar uma pessoa
export async function adicionarPessoa(fd: FormData) {
  await exigirAdmin();
  const r = await criar(String(fd.get("nome") ?? ""), String(fd.get("cargo") ?? ""));
  if (!r.ok) throw new Error(r.erro);
  revalidatePath("/", "layout");
}

// Configurações: cria de uma vez as contas dos nomes que aparecem no fluxo
export async function criarContasDoFluxo() {
  await exigirAdmin();
  const admin = createAdminClient();
  const [{ data: etapas }, { data: perfis }] = await Promise.all([
    admin.from("etapas").select("area,responsaveis_label,ordem").eq("ativo", true).order("ordem"),
    admin.from("profiles").select("nome").eq("tipo", "equipe"),
  ]);
  const existentes = new Set((perfis ?? []).map((p) => primeiroNome(p.nome ?? "")));
  const pessoas = new Map<string, { nome: string; cargo: string }>();
  for (const e of etapas ?? []) {
    for (const bruto of (e.responsaveis_label ?? "").split(/\s*[\/,;&]\s*|\s+e\s+/)) {
      const nome = bruto.trim();
      if (!nome || /depende/i.test(nome)) continue;
      const chave = primeiroNome(nome);
      if (!existentes.has(chave) && !pessoas.has(chave)) {
        pessoas.set(chave, { nome: nome.charAt(0).toUpperCase() + nome.slice(1).toLowerCase(), cargo: e.area });
      }
    }
  }
  for (const p of pessoas.values()) {
    const r = await criar(p.nome, p.cargo);
    if (!r.ok) throw new Error(`${p.nome}: ${r.erro}`);
  }
  revalidatePath("/", "layout");
}

// Configurações: volta a senha de alguém para nome+2026
export async function resetarSenha(fd: FormData) {
  await exigirAdmin();
  const id = String(fd.get("id") ?? "");
  const admin = createAdminClient();
  const { data: perfil } = await admin.from("profiles").select("nome").eq("id", id).eq("tipo", "equipe").single();
  if (!perfil?.nome) throw new Error("Pessoa não encontrada");
  const { error } = await admin.auth.admin.updateUserById(id, { password: senhaPadrao(perfil.nome) });
  if (error) throw new Error(error.message);
  await admin.from("profiles").update({ trocar_senha: true }).eq("id", id);
  revalidatePath("/configuracoes");
}

// Primeiro acesso: troca a senha padrão
export async function trocarSenha(senha: string): Promise<{ erro?: string }> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { erro: "Sessão expirada, entre de novo" };
  if (senha.length < 6) return { erro: "A senha precisa ter pelo menos 6 caracteres" };
  const { data: perfil } = await supabase.from("profiles").select("nome").eq("id", user.id).single();
  if (perfil?.nome && senha === senhaPadrao(perfil.nome)) return { erro: "Escolha uma senha diferente da inicial" };
  const { error } = await supabase.auth.updateUser({ password: senha });
  if (error) return { erro: error.message };
  await supabase.from("profiles").update({ trocar_senha: false }).eq("id", user.id);
  return {};
}

// ---------------------------------------------------------------------
// Portal do cliente: contas de acesso (criadas pela equipe)
// ---------------------------------------------------------------------
type Acesso = { ok: true; usuario: string; senha: string } | { ok: false; erro: string };

function senhaAleatoria() {
  const letras = "abcdefghjkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return Array.from(bytes, (b) => letras[b % letras.length]).join("");
}

export async function criarAcessoPortal(clienteId: string, nome: string): Promise<Acesso> {
  try {
    await exigirLogado();
    nome = nome.trim();
    if (nome.length < 2) return { ok: false, erro: "Informe o nome da pessoa do cliente" };
    const admin = createAdminClient();
    const { data: cliente } = await admin.from("clientes").select("id,nome").eq("id", clienteId).single();
    if (!cliente) return { ok: false, erro: "Cliente não encontrado" };
    const base = normaliza(`${primeiroNome(nome)}.${primeiroNome(cliente.nome)}`);
    const usuario = await usuarioLivre(base, nome);
    const senha = senhaAleatoria();
    const { error } = await admin.auth.admin.createUser({
      email: `${usuario}@${DOMINIO_LOGIN}`,
      password: senha,
      email_confirm: true,
      user_metadata: { nome, usuario, trocar_senha: true, tipo: "cliente", cliente_id: cliente.id },
    });
    if (error) return { ok: false, erro: traduzErro(error.message) };
    revalidatePath(`/clientes/${clienteId}`);
    return { ok: true, usuario, senha };
  } catch (e) {
    console.error("criarAcessoPortal", e);
    return { ok: false, erro: traduzErro(e instanceof Error ? e.message : String(e)) };
  }
}

async function perfilCliente(id: string) {
  const admin = createAdminClient();
  const { data } = await admin.from("profiles").select("id,usuario,cliente_id").eq("id", id).eq("tipo", "cliente").single();
  if (!data) throw new Error("Acesso não encontrado");
  return { admin, perfil: data };
}

export async function novaSenhaPortal(id: string): Promise<Acesso> {
  try {
    await exigirLogado();
    const { admin, perfil } = await perfilCliente(id);
    const senha = senhaAleatoria();
    const { error } = await admin.auth.admin.updateUserById(id, { password: senha });
    if (error) return { ok: false, erro: traduzErro(error.message) };
    await admin.from("profiles").update({ trocar_senha: true }).eq("id", id);
    return { ok: true, usuario: perfil.usuario ?? "", senha };
  } catch (e) {
    return { ok: false, erro: traduzErro(e instanceof Error ? e.message : String(e)) };
  }
}

export async function removerAcessoPortal(fd: FormData) {
  await exigirLogado();
  const { admin, perfil } = await perfilCliente(String(fd.get("id") ?? ""));
  const { error } = await admin.auth.admin.deleteUser(perfil.id);
  if (error) throw new Error(traduzErro(error.message));
  revalidatePath(`/clientes/${perfil.cliente_id}`);
}
