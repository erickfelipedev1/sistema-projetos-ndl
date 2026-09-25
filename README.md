# Controle de Processos (sistema-projetos-ndl v2)

Fluxo: CS (apresentação/montagem) → Projetos (Flex 10 · Full 15 · Premium 25) → Agenciamento (cotação, 1 ou 2 c/ certificação) → Projetos (estimativa, 2) → CS (apresentação da estimativa) → CX → Agenciamento (booking) → Viagem → Desembaraço → Liberado → Transporte → Chegou.
Os prazos são em dias úteis (sem fim de semana e sem os feriados cadastrados).

## 1. Banco (Supabase)
SQL Editor → New query → cole `supabase/001_controle_processos.sql` → Run. Depois, uma query de cada vez, `002_prazo_por_plano_certificacao.sql`, `003_cargo_no_cadastro.sql`, `004_login_por_usuario.sql`, `005_checklist_sourcing.sql`, `006_fechamento_gerenciamento_emails.sql` e `007_situacao_proxima_acao.sql` → Run.
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

Variáveis de ambiente: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` (Supabase → Project Settings → API Keys → service_role / secret). A service role fica só no servidor — nunca com prefixo NEXT_PUBLIC.

## 3. Primeiro uso
1. Login = primeiro nome, senha inicial = primeiro nome + 2026 (ex.: larissa / larissa2026). Crie as contas em Configurações → "Criar contas de todos os responsáveis do fluxo", ou cada pessoa usa "Primeiro acesso" na tela de login. No primeiro login a pessoa troca a senha. Cada conta é vinculada automaticamente às etapas com o primeiro nome dela.
2. Em **Configurações**, marque os responsáveis padrão de cada etapa. A partir daí, cada processo cai sozinho em "Minhas tarefas" da pessoa certa.
3. Em **Processos → + Novo processo**, cadastre os processos que hoje estão no Monday, depois avance cada um até a etapa em que ele está.

## Telas
- **Painel**: KPIs (ativos, em atraso, vencem hoje/amanhã, tempo médio, previsão média), fluxo das 12 etapas, análise de gargalos (realizado × prazo), maiores atrasos, próximas entregas e atividades recentes.
- **Processos**: kanban das 12 etapas ou lista, filtros (responsável, plano, certificação, status, etapa, busca), abas Ativos / Concluídos / Cancelados.
- **Processo**: cabeçalho com responsável, etapa, previsão e status; timeline das 12 etapas; etapa atual com "por que está aqui?", concluir e avançar, ajustar prazo, trocar responsável; abas Checklist, E-mails, Comentários, Histórico e Dados.
- **Novo processo**: assistente em 4 passos (Cliente, Configuração, Responsáveis, Revisão) com previsão de chegada calculada.
- **Minhas tarefas**: o que está com você, por atrasadas / vencem hoje / próximas.
- **Manual**: fluxo geral, cada etapa com checklist e modelos relacionados, saudação, formulários, INPI e tabela de prazos.
- **E-mails**: biblioteca de modelos preenchidos com os dados de um processo.
- **Configurações**: Fluxo, Equipe, Operação e Sistema.

## Estrutura do código
- `components/ui/`: componentes compartilhados (KpiCard, StatusBadge, ProgressBar, Avatar, Tabs, FilterBar, Modal/Drawer, Menu, EmptyState, ActivityTimeline, SubmitButton).
- `components/processos/`: ProcessCard, StageColumn, ProcessTimeline, NovoProcessoWizard.
- `components/painel/`: FlowStrip, BottleneckChart.
- `lib/status.ts`: regras de status, prazo e "motivo" usadas em todas as telas. `lib/dados.ts`: consultas e cálculos (previsão, médias).
- Cores e tipografia: tokens em `app/globals.css` (`@theme`).

## v9 — Clientes, portal do cliente, chat e anexos

1. Rode `supabase/008_clientes_portal_chat_anexos.sql` no SQL Editor (ou o `000_tudo.sql`, que já inclui tudo).
   - Cria o cadastro de clientes e vincula cada processo existente ao seu cliente (pelo nome da empresa).
   - Cria o bucket privado `anexos` no Storage (confira em Storage › Buckets).
2. **Clientes** (`/clientes`): cadastro, processos, arquivos do cliente e acesso ao portal.
3. **Portal do cliente** (`/portal`): o cliente entra com o usuário gerado e vê só as etapas e datas.
4. **Chat e demandas** (`/chat`): canal Geral, conversas diretas e demandas com responsável, processo e prazo.
5. **Anexos**: aba Anexos no processo (por etapa + arquivos gerais) e botão "Anexar arquivo" na etapa atual.
6. Recomendado: em Supabase › Authentication › Sign In / Providers, desligue "Allow new users to sign up" (as contas são criadas pelo servidor).

## v10 — Aguardando o cliente (Onboarding e Apresentação da estimativa)

Rode `supabase/009_aguardando_cliente.sql` (já incluído no `000_tudo.sql`).

- A etapa 1 passa a se chamar **Onboarding**. O checklist dela é: enviar o onboarding (1 dia útil), enviar o formulário, aguardar o formulário e mandar o e-mail para Projetos.
- **Apresentação da estimativa**: marcar a reunião de sourcing (1 dia útil), aguardar a devolutiva e mandar a devolutiva para o CX.
- Enquanto o próximo item é de "espera do cliente", o prazo fica pausado e a etapa não entra como atrasada. A cada 7 dias aparece "Cobrar cliente", e o botão "Registrar cobrança" guarda a cobrança no histórico.
- Quando o item de espera é marcado, a etapa ganha 1 dia útil (configurável) para terminar.
- Em Configurações › Checklists, qualquer item pode virar "Espera do cliente".
- No portal, o cliente vê "Estamos aguardando o formulário" quando a etapa depende dele.

## v11 — Cotação de frete e Estimativa dentro de Projetos

Rode `supabase/010_projetos_cotacao_estimativa.sql` (já incluído no `000_tudo.sql`).

- O fluxo passa a ter 10 etapas. Cotação de frete e Estimativa de custo viram itens do checklist de **Projetos**, e o prazo 10/15/25 já cobre esses itens.
- Os itens com responsável mandam uma **demanda automática** no chat quando o item anterior é marcado:
  - Cotação internacional: Isabella/Cris, 1 dia útil (2 com certificação).
  - Cotação rodoviária: Isabella/Cris, 1 dia útil.
  - Montagem da estimativa: Alycia, 2 dias úteis.
- A demanda aparece em Minhas tarefas › "Demandas para você" e no Chat. Concluir a demanda marca o item no checklist, e marcar o item conclui a demanda.
- Processos que estavam em Cotação ou Estimativa voltam para Projetos no ponto certo do checklist, com o prazo original.
- Em Configurações › Checklists, cada item pode ter responsável e prazo próprios.

## v12 — Permissões por área

Rode `supabase/011_permissoes_por_area.sql` (já incluído no `000_tudo.sql`).

- **Todo mundo vê tudo**, e qualquer pessoa pode comentar e anexar arquivos.
- **Marcar checklist, avançar, voltar, prazo, responsável, situação e cobrança** de uma etapa ficam liberados só para:
  - quem é da área (cargo igual à área da etapa, ex.: CS no Onboarding);
  - quem é responsável pela etapa;
  - administradores.
- **Itens com responsável próprio** (cotação → Isabella/Cris, estimativa → Alycia) só podem ser marcados por essas pessoas. A demanda ligada ao item só pode ser concluída por quem a recebeu.
- **Administrador**: altera a configuração do fluxo e define o cargo e o acesso de administrador de cada pessoa em Configurações › Equipe › Usuários.
  - Depois que o cargo de alguém é definido, só um administrador consegue mudá-lo.
  - Quem já tem cargo de Gestão vira administrador ao rodar o SQL. Se ninguém tiver, o Erick vira.
- As regras valem no banco de dados, não só na tela.
