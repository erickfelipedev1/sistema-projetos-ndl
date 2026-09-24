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

export async function criarProcesso(fd: FormData) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("criar_processo", {
    p_cliente: txt(fd, "cliente"),
    p_plano: txt(fd, "plano"),
    p_descricao: txt(fd, "descricao"),
  });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
  redirect(`/processos/${data}`);
}

export async function avancarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const { error } = await supabase.rpc("avancar_processo", { p_processo_id: id, p_obs: txt(fd, "obs") });
  if (error) falhou(error.message);
  revalidatePath("/", "layout");
}

export async function retornarProcesso(fd: FormData) {
  const supabase = await createClient();
  const id = txt(fd, "processo_id");
  const { error } = await supabase.rpc("retornar_processo", { p_processo_id: id, p_motivo: txt(fd, "motivo") });
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
    .update({ cliente: txt(fd, "cliente"), plano: txt(fd, "plano") || null, descricao: txt(fd, "descricao") || null })
    .eq("id", id);
  if (error) falhou(error.message);
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
  const id = Number(txt(fd, "id"));
  const prazo = txt(fd, "prazo_dias_uteis");
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

export async function salvarMeuNome(fd: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return;
  await supabase.from("profiles").update({ nome: txt(fd, "nome") }).eq("id", user.id);
  revalidatePath("/", "layout");
}

export async function sair() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
