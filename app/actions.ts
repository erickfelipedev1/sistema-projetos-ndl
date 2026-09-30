"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function txt(fd: FormData, k: string) {
  const v = fd.get(k);
  return typeof v === "string" ? v.trim() : "";
}

function falhou(msg: string): never {
  throw new Error(msg);
}

async function exigirAdmin(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data } = await supabase.rpc("is_admin");
  if (data !== true) falhou("Só um administrador pode alterar a configuração do fluxo");
}

export async function criarProcesso(fd: FormData) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("criar_processo_completo", {
    p_cliente: txt(fd, "cliente"),
    p_plano: txt(fd, "plano"),
    p_descricao: txt(fd, "descricao"),
    p_certificacao: fd.get("certificacao") === "on",
    p_cliente_id: txt(fd, "cliente_id") || null,
    p_contato: txt(fd, "contato") || null,
    p_gerenciamento: txt(fd, "gerenciamento") || null,
  });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
  redirect(`/processos/${data}`);
}

export async function avancarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const { error } = await supabase.rpc("avancar_etapa", { p_processo_id: id, p_obs: txt(fd, "obs") });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function retornarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const { error } = await supabase.rpc("retornar_etapa", { p_processo_id: id, p_motivo: txt(fd, "motivo") });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

async function registrar(processoId: string, tipo: string, texto: string) {
  const supabase = await createClient();
  await supabase.from("processo_eventos").insert({ processo_id: processoId, tipo, texto });
}

export async function alterarPrazo(fd: FormData) {
  const supabase = await createClient();
  const peId = txt(fd, "pe_id");
  const processoId = txt(fd, "processo_id");
  const prazo = txt(fd, "prazo_em");
  const etapa = txt(fd, "etapa_nome");
  const { error } = await supabase.from("processo_etapas").update({ prazo_em: prazo || null }).eq("id", peId);
  if (error) falhou(error.message);
  const [y, m, d] = prazo.split("-");
  await registrar(processoId, "prazo", `Prazo de "${etapa}" alterado para ${prazo ? `${d}/${m}/${y}` : "sem prazo"}`);
  revalidatePath("/", "layout");
}

export async function alterarResponsaveis(fd: FormData) {
  const supabase = await createClient();
  const peId = txt(fd, "pe_id");
  const processoId = txt(fd, "processo_id");
  const etapa = txt(fd, "etapa_nome");
  const ids = fd.getAll("responsaveis").map(String).filter(Boolean);
  const { error } = await supabase.from("processo_etapas").update({ responsaveis: ids }).eq("id", peId);
  if (error) falhou(error.message);
  const { data: perfis } = await supabase.from("profiles").select("id,nome").in("id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]);
  const nomes = (perfis ?? []).map((p) => p.nome).join(" / ") || "ninguém";
  await registrar(processoId, "responsavel", `Responsável de "${etapa}": ${nomes}`);
  revalidatePath("/", "layout");
}

export async function comentar(fd: FormData) {
  const texto = txt(fd, "texto");
  const processoId = txt(fd, "processo_id");
  if (!texto) return;
  await registrar(processoId, "comentario", texto);
  revalidatePath(`/processos/${processoId}`);
}

export async function editarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const { error } = await supabase
    .from("processos")
    .update({
      ...(txt(fd, "cliente_id") ? { cliente_id: txt(fd, "cliente_id") } : { cliente: txt(fd, "cliente") }),
      plano: txt(fd, "plano") || null,
      descricao: txt(fd, "descricao") || null,
      certificacao: fd.get("certificacao") === "on",
      contato: txt(fd, "contato") || null,
      gerenciamento: txt(fd, "gerenciamento") || null,
    })
    .eq("id", id);
  if (error) falhou(error.message);
  const { error: e2 } = await supabase.rpc("recalcular_prazos_seguro", { p_processo_id: id });
  if (e2) falhou(e2.message);
  revalidatePath("/", "layout");
}

export async function cancelarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const reativar = txt(fd, "reativar") === "1";
  const { error } = await supabase.from("processos").update({ status: reativar ? "ativo" : "cancelado" }).eq("id", id);
  if (error) falhou(error.message);
  await registrar(id, "status", reativar ? "Processo reativado" : `Processo cancelado${txt(fd, "motivo") ? `: ${txt(fd, "motivo")}` : ""}`);
  revalidatePath("/", "layout");
}

// ---------- Configurações ----------

export async function salvarEtapa(fd: FormData) {
  const supabase = await createClient();
  await exigirAdmin(supabase);
  const id = Number(txt(fd, "id"));
  const prazo = txt(fd, "prazo_dias_uteis");
  const num = (k: string) => (txt(fd, k) === "" ? null : Number(txt(fd, k)));
  const payload = {
    ordem: Number(txt(fd, "ordem")),
    area: txt(fd, "area"),
    nome: txt(fd, "nome"),
    tipo: txt(fd, "tipo") || "tarefa",
    prazo_dias_uteis: prazo === "" ? null : Number(prazo),
    prazo_editavel: fd.get("prazo_editavel") === "on",
    responsaveis_label: txt(fd, "responsaveis_label") || null,
    responsaveis_padrao: fd.getAll("responsaveis_padrao").map(String).filter(Boolean),
    ativo: fd.get("ativo") === "on",
    prazo_flex: num("prazo_flex"),
    prazo_full: num("prazo_full"),
    prazo_premium: num("prazo_premium"),
    prazo_com_certificacao: num("prazo_com_certificacao"),
  };
  const { error } = id
    ? await supabase.from("etapas").update(payload).eq("id", id)
    : await supabase.from("etapas").insert(payload);
  if (error) falhou(error.message);
  revalidatePath("/configuracoes");
}

export async function aplicarResponsaveisEmAndamento(fd: FormData) {
  // aplica os responsáveis padrão da etapa aos processos que estão nela agora
  const supabase = await createClient();
  await exigirAdmin(supabase);
  const id = Number(txt(fd, "id"));
  const { data: etapa } = await supabase.from("etapas").select("responsaveis_padrao").eq("id", id).single();
  if (!etapa) return;
  const { error } = await supabase
    .from("processo_etapas")
    .update({ responsaveis: etapa.responsaveis_padrao })
    .eq("etapa_id", id)
    .neq("status", "concluida");
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function salvarFeriado(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("feriados").upsert({ data: txt(fd, "data"), descricao: txt(fd, "descricao") });
  if (error) falhou(error.message);
  revalidatePath("/configuracoes");
}

export async function removerFeriado(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("feriados").delete().eq("data", txt(fd, "data"));
  if (error) falhou(error.message);
  revalidatePath("/configuracoes");
}

export async function salvarMeuPerfil(fd: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;
  const { error } = await supabase.from("profiles").update({ nome: txt(fd, "nome"), ...(txt(fd, "cargo") ? { cargo: txt(fd, "cargo") } : {}) }).eq("id", user.id);
  if (error) falhou(error.message);
  await supabase.rpc("vincular_minhas_etapas");
  revalidatePath("/", "layout");
}

export async function sair() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

// ---------- Checklist ----------

export async function marcarChecklist(id: string, feito: boolean) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("processo_checklist")
    .update({ feito, feito_por: feito ? user?.id ?? null : null, feito_em: feito ? new Date().toISOString() : null })
    .eq("id", id);
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function salvarItemChecklist(fd: FormData) {
  const supabase = await createClient();
  await exigirAdmin(supabase);
  const id = Number(txt(fd, "id"));
  const payload = {
    etapa_id: Number(txt(fd, "etapa_id")),
    ordem: Number(txt(fd, "ordem")),
    titulo: txt(fd, "titulo"),
    descricao: txt(fd, "descricao") || null,
    ativo: fd.get("ativo") === "on",
    condicao: txt(fd, "condicao") || null,
    aguarda_cliente: fd.get("aguarda_cliente") === "on",
    prazo_depois: fd.get("aguarda_cliente") === "on" ? Number(txt(fd, "prazo_depois") || 1) : null,
    responsaveis: fd.getAll("item_responsaveis").map(String).filter(Boolean),
    prazo_item: txt(fd, "prazo_item") ? Number(txt(fd, "prazo_item")) : null,
    prazo_item_cert: txt(fd, "prazo_item_cert") ? Number(txt(fd, "prazo_item_cert")) : null,
  };
  const { error } = id
    ? await supabase.from("checklist_modelo").update(payload).eq("id", id)
    : await supabase.from("checklist_modelo").insert(payload);
  if (error) falhou(error.message);
  revalidatePath("/configuracoes");
  revalidatePath("/manual");
}

export async function salvarTexto(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("textos").upsert({ chave: txt(fd, "chave"), conteudo: txt(fd, "conteudo") });
  if (error) falhou(error.message);
  revalidatePath("/manual");
  revalidatePath("/configuracoes");
}

export async function salvarEmailModelo(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("email_modelos")
    .update({
      titulo: txt(fd, "titulo"),
      para: txt(fd, "para") || null,
      assunto: txt(fd, "assunto") || null,
      corpo: txt(fd, "corpo"),
      ativo: fd.get("ativo") === "on",
    })
    .eq("id", Number(txt(fd, "id")));
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function definirSituacao(fd: FormData) {
  const supabase = await createClient();
  const peId = txt(fd, "pe_id");
  const processoId = txt(fd, "processo_id");
  const situacao = txt(fd, "situacao");
  const { error } = await supabase.from("processo_etapas").update({ situacao: situacao || null }).eq("id", peId);
  if (error) falhou(error.message);
  await supabase.from("processo_eventos").insert({
    processo_id: processoId, tipo: "situacao",
    texto: situacao ? `Situação atualizada: ${situacao}` : "Situação removida",
  });
  revalidatePath("/", "layout");
}

export async function salvarResponsaveisPadrao(fd: FormData) {
  const supabase = await createClient();
  await exigirAdmin(supabase);
  const id = Number(txt(fd, "id"));
  const ids = fd.getAll("responsaveis_padrao").map(String).filter(Boolean);
  const { error } = await supabase.from("etapas").update({ responsaveis_padrao: ids, responsaveis_label: txt(fd, "responsaveis_label") || null }).eq("id", id);
  if (error) falhou(error.message);
  if (fd.get("aplicar") === "on") {
    const { error: e2 } = await supabase.from("processo_etapas").update({ responsaveis: ids }).eq("etapa_id", id).neq("status", "concluida");
    if (e2) falhou(e2.message);
  }
  revalidatePath("/", "layout");
}

export async function salvarOrdemEtapas(fd: FormData) {
  const supabase = await createClient();
  await exigirAdmin(supabase);
  const pares = [...fd.entries()].filter(([k]) => k.startsWith("ordem_")).map(([k, v]) => [Number(k.slice(6)), Number(v)] as const);
  for (const [id, ordem] of pares) {
    const { error } = await supabase.from("etapas").update({ ordem }).eq("id", id);
    if (error) falhou(error.message);
  }
  revalidatePath("/", "layout");
}

export async function alterarMinhaSenha(fd: FormData) {
  const supabase = await createClient();
  const senha = txt(fd, "senha");
  if (senha.length < 6) falhou("A senha precisa ter pelo menos 6 caracteres");
  if (senha !== txt(fd, "confirma")) falhou("As senhas não conferem");
  const { error } = await supabase.auth.updateUser({ password: senha });
  if (error) falhou(error.message);
}

// ---------------------------------------------------------------------
// Clientes
// ---------------------------------------------------------------------
export async function salvarCliente(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "id");
  const dados = {
    nome: txt(fd, "nome"),
    cnpj: txt(fd, "cnpj") || null,
    contato: txt(fd, "contato") || null,
    email: txt(fd, "email") || null,
    telefone: txt(fd, "telefone") || null,
    observacoes: txt(fd, "observacoes") || null,
  };
  if (!dados.nome) falhou("Informe o nome do cliente");
  if (id) {
    const { error } = await supabase.from("clientes").update(dados).eq("id", id);
    if (error) falhou(error.code === "23505" ? "Já existe um cliente com esse nome" : error.message);
    revalidatePath("/", "layout");
    return;
  }
  const { data, error } = await supabase.from("clientes").insert(dados).select("id").single();
  if (error) falhou(error.code === "23505" ? "Já existe um cliente com esse nome" : error.message);
  revalidatePath("/clientes");
  redirect(`/clientes/${data.id}`);
}

// ---------------------------------------------------------------------
// Chat: demandas
// ---------------------------------------------------------------------
export async function concluirDemanda(fd: FormData) {
  const supabase = await createClient();
  const reabrir = txt(fd, "reabrir") === "1";
  const { error } = await supabase
    .from("mensagens")
    .update({ demanda_status: reabrir ? "aberta" : "concluida", demanda_concluida_em: reabrir ? null : new Date().toISOString() })
    .eq("id", Number(txt(fd, "id")));
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

// ---------------------------------------------------------------------
// Anexos: link temporário para baixar e exclusão
// ---------------------------------------------------------------------
export async function linkAnexo(id: string): Promise<string | null> {
  const supabase = await createClient();
  const { data: a } = await supabase.from("anexos").select("caminho,nome").eq("id", id).maybeSingle();
  if (!a) return null;
  const { data } = await supabase.storage.from("anexos").createSignedUrl(a.caminho, 120, { download: a.nome });
  return data?.signedUrl ?? null;
}

export async function excluirAnexo(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "id");
  const { data: a } = await supabase.from("anexos").select("caminho,nome,processo_id").eq("id", id).maybeSingle();
  if (!a) return;
  await supabase.storage.from("anexos").remove([a.caminho]);
  const { error } = await supabase.from("anexos").delete().eq("id", id);
  if (error) falhou(error.message);
  if (a.processo_id) await registrar(a.processo_id, "anexo", `Arquivo removido: ${a.nome}`);
  revalidatePath("/", "layout");
}

export async function registrarAnexo(processoId: string, nome: string) {
  await registrar(processoId, "anexo", `Arquivo anexado: ${nome}`);
  revalidatePath(`/processos/${processoId}`);
}

export async function excluirCliente(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "id");
  const { count } = await supabase.from("processos").select("id", { count: "exact", head: true }).eq("cliente_id", id);
  if (count) falhou("Este cliente tem processos e não pode ser excluído");
  const { error } = await supabase.from("clientes").delete().eq("id", id);
  if (error) falhou(error.message);
  revalidatePath("/clientes");
  redirect("/clientes");
}

// ---------------------------------------------------------------------
// Aguardando cliente: registrar a cobrança semanal
// ---------------------------------------------------------------------
export async function registrarCobranca(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("registrar_cobranca", { p_pe_id: txt(fd, "pe_id"), p_obs: txt(fd, "obs") || null });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

// ---------------------------------------------------------------------
// Administrador: cargo e acesso de administrador de uma pessoa
// ---------------------------------------------------------------------
export async function definirPessoa(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("definir_pessoa", {
    p_user: txt(fd, "id"), p_cargo: txt(fd, "cargo"), p_admin: fd.get("admin") === "on",
  });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function souAdmin() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("is_admin");
  return data === true;
}

export async function pausarProcesso(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("pausar_processo", {
    p_processo_id: txt(fd, "processo_id"), p_pausar: txt(fd, "retomar") !== "1", p_motivo: txt(fd, "motivo") || null,
  });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

// ---------------------------------------------------------------------
// Fornecedores
// ---------------------------------------------------------------------
export async function salvarFornecedor(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "id");
  const dados = {
    nome: txt(fd, "nome"),
    produto: txt(fd, "produto") || null,
    contato: txt(fd, "contato") || null,
    origem: txt(fd, "origem") || null,
    telefone: txt(fd, "telefone") || null,
    email: txt(fd, "email") || null,
    site: txt(fd, "site") || null,
    avaliacao: txt(fd, "avaliacao") ? Number(txt(fd, "avaliacao")) : null,
    observacoes: txt(fd, "observacoes") || null,
  };
  if (!dados.nome) falhou("Informe o nome do fornecedor");
  if (id) {
    const { error } = await supabase.from("fornecedores").update(dados).eq("id", id);
    if (error) falhou(error.message);
  } else {
    const { error } = await supabase.from("fornecedores").insert(dados);
    if (error) falhou(error.message);
  }
  revalidatePath("/fornecedores");
}

export async function excluirFornecedor(fd: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("fornecedores").delete().eq("id", txt(fd, "id"));
  if (error) falhou(error.message);
  revalidatePath("/fornecedores");
}
