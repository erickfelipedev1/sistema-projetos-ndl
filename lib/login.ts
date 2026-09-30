// Regras de login por usuário (usadas no navegador e no servidor)
export const DOMINIO_LOGIN = "controle-processos.app"; // e-mail interno, nunca recebe mensagens

export function normaliza(t: string) {
  return t
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9.]/g, "");
}

export function primeiroNome(nome: string) {
  return normaliza(nome.trim().split(/\s+/)[0] ?? "");
}

export function emailDoLogin(login: string) {
  const l = login.trim();
  return l.includes("@") ? l.toLowerCase() : `${normaliza(l)}@${DOMINIO_LOGIN}`;
}

// senha inicial = primeiro nome + 2026 (ex.: larissa2026)
export function senhaPadrao(nome: string) {
  return `${primeiroNome(nome)}2026`;
}
