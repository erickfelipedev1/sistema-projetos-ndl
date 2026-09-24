# Controle de Processos (sistema-projetos-ndl v2)

Fluxo: CS → Projetos → Agenciamento (cotação) → Projetos (estimativa) → CX → Agenciamento (booking) → Viagem → Desembaraço → Liberado → Transporte → Chegou.
Os prazos são em dias úteis (sem fim de semana e sem os feriados cadastrados).

## 1. Banco (Supabase)
SQL Editor → New query → cole `supabase/001_controle_processos.sql` → Run.
Cria as tabelas novas e cadastra as 11 etapas e os feriados de 2026/2027. As tabelas antigas do sistema não são apagadas.

## 2. Código (PowerShell, dentro da pasta do repositório)
```powershell
git checkout -b v2-processos
Remove-Item -Recurse -Force app, components, lib, middleware.ts -ErrorAction SilentlyContinue
# copie o conteúdo deste zip para a pasta (mantenha seu .env.local)
npm install
npm run dev
```
Abra http://localhost:3000. Quando estiver ok:
```powershell
git add -A
git commit -m "v2: controle de processos"
git push -u origin v2-processos
```
A Vercel gera um preview dessa branch. Depois de validar, faça o merge na main.

Variáveis de ambiente (as mesmas de antes): `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY`.

## 3. Primeiro uso
1. Cada pessoa (Larissa, Ana, Isabella, Cris, Alycia, Rodrigo, Leonardo) cria a conta na tela de login.
2. Em **Configurações**, marque os responsáveis padrão de cada etapa. A partir daí, cada processo cai sozinho em "Minhas tarefas" da pessoa certa.
3. Em **Processos → + Novo processo**, cadastre os processos que hoje estão no Monday, depois avance cada um até a etapa em que ele está.

## Telas
- **Painel**: processos ativos, etapas atrasadas, o que vence hoje ou amanhã, e onde o fluxo trava (média real × prazo por etapa).
- **Processos**: kanban por etapa, com filtros por cliente, responsável e plano, e abas de concluídos e cancelados.
- **Processo**: concluir etapa e avançar, ajustar prazo (ETA da viagem), trocar responsável, voltar etapa, histórico e comentários, previsão de chegada.
- **Minhas tarefas**: o que está com você, separado em atrasado, vence hoje ou amanhã, e próximas.
- **Configurações**: etapas (ordem, prazo, responsáveis), feriados, equipe.
