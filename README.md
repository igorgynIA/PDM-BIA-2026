# Silver — Crimes de Chicago × dias de jogo

Documentação da camada Silver do pipeline Medallion no BigQuery. A camada
Gold ainda não existe; este documento cobre só o que já está pronto e
validado: as duas tabelas Silver, as decisões de limpeza tomadas em cada
uma, e as limitações conhecidas.

Projeto GCP: `pdm-crimes-chicago` · Dataset: `crimes_chicago`

## Arquivos

| Arquivo | O que faz |
|---|---|
| `01_crimes_silver.sql` | Bronze → Silver de crimes (`tb_crimes_silver`) |
| `02_jogos_silver.sql` | Bronze → Silver de jogos (`tb_jogos_silver_igor`) |
| `03_analises_qualidade.sql` | Consultas de apoio que embasaram as decisões abaixo |

Cada script começa com um comentário explicando o que faz e por quê — não é
preciso ler este README e o SQL como coisas separadas.

---

## `tb_crimes_silver`

Origem: `tb_crimes_bronze`, cópia fiel do dataset público `bigquery-public-data.chicago_crime.crime`.

| Coluna | Descrição |
|---|---|
| `unique_key` | Identificador único do registro (chave de deduplicação) |
| `data_hora_local_chicago` | Timestamp original, já confirmado em horário local de Chicago |
| `data_ocorrencia` | Só a data (usada como grão da futura Gold) |
| `hora_ocorrencia` | Hora extraída (0–23) — mantida na tabela, mas não usada na análise principal (ver Limitações) |
| `distrito_policial` | Distrito policial (1–25), com nulos recuperados via `beat` quando possível |
| `beat` | Menor unidade geográfica da polícia, mantida para rastreabilidade |
| `tipo_crime` | Categoria principal do crime (`primary_type`) |
| `descricao_crime` | Subcategoria do crime (`description`) |
| `local_ocorrencia` | Tipo de local onde o crime ocorreu (`location_description`) |
| `houve_prisao` | Booleano |
| `eh_domestico` | Booleano |
| `latitude` / `longitude` | `NULL` quando ausente ou fora de uma caixa aproximada da cidade |
| `ano` | Ano do registro |

### Decisões de limpeza

**Deduplicação.** Por `unique_key`. Nenhuma regra adicional foi necessária:
investigamos os grupos de registros com mesmo `case_number`+`date`+`block`+`iucr`
e 100% deles são `HOMICIDE` (média de 2,2 registros por grupo) — é o
comportamento documentado da própria fonte, uma linha por vítima, não
duplicata de ingestão.

**Distrito ausente.** Recuperado via uma dimensão auxiliar `beat → distrito`,
construída a partir da moda estatística dos próprios dados (cada `beat`
pertence geograficamente a um único distrito, então essa imputação é segura).
Verificamos que 42 registros de todo o histórico dependem de um `beat` que já
esteve associado a mais de um distrito — impacto desprezível, não tratado.
Registros sem `district` nem `beat` recuperável, ou com distrito fora de
1–25, são **descartados**.

**Fuso horário.** O campo `date` já vem em horário local de Chicago — isso
foi confirmado empiricamente (a distribuição de crimes por hora extraída
direto do campo bate com o padrão criminológico esperado: baixa de
madrugada, pico à noite). Nenhuma conversão foi aplicada.

**Coordenadas.** Cerca de 98 mil registros vêm sem latitude/longitude, e 149
caem fora de uma caixa aproximada da cidade de Chicago (41,64–42,03 N,
-87,95 a -87,52 W). Em ambos os casos, a coordenada vira `NULL`, mas a
tupla **não é descartada** — ela continua válida para qualquer métrica
agregada por distrito, só não deve ser usada num mapa de pontos. Optamos
por não imputar uma coordenada artificial (ex: centroide do distrito), pois
isso criaria concentrações falsas em qualquer visualização espacial.

---

## `tb_jogos_silver_igor`

Origem: `tb_jogos_bronze`, que guarda o registro cru de cada liga numa coluna
JSON (`registro`), com schemas completamente diferentes entre NFL, MLB, NBA
e NHL.

| Coluna | Descrição |
|---|---|
| `id_jogo`, `liga`, `temporada` | Identificação do jogo |
| `data_jogo` | Data local do jogo em Chicago |
| `horario_inicio_chicago` | Horário de início convertido para fuso de Chicago; `NULL` para todos os jogos da NHL (a fonte não traz horário) |
| `time_casa` | Um dos 5 times de Chicago: Bulls, Cubs, White Sox, Bears, Blackhawks |
| `distrito_policial` | Distrito onde fica o estádio do time da casa |
| `adversario`, `placar_casa`, `placar_visitante`, `vitoria_casa` | Dados do confronto |

Só entram jogos em que o **time de Chicago joga em casa** — é isso que gera
concentração de pessoas na cidade. Jogos fora (ex: Bears em Detroit) são
descartados, e o adversário nunca precisa de mapeamento de distrito próprio,
mesmo quando é outro time de Chicago olhando o calendário completo da liga.

### Decisões de limpeza, por liga

**NFL (Bears, Soldier Field, distrito 1).** O campo `gametime` vem em
horário do Leste dos EUA, não de Chicago — convertido explicitamente
(`America/New_York` → `America/Chicago`). Jogos futuros são excluídos por
data (`data_jogo < CURRENT_DATE()`), não por placar nulo — mais robusto,
cobre também jogos cancelados/adiados. Confirmamos que não existe
pré-temporada (`game_type = 'PRE'` ou similar) nos dados.

**MLB (Cubs e White Sox, Wrigley Field/distrito 19 e Guaranteed Rate
Field/distrito 9).** `gameDate` vem com sufixo `Z` (UTC real), convertido
para Chicago sem ambiguidade. Jogos de Spring Training (jogados no Arizona)
são excluídos via `game_type`, mantendo só temporada regular e pós-temporada;
jogos não finalizados são excluídos via `status_code`.

**NBA (Bulls, United Center, distrito 12).** `game_date_time` já vem com
offset explícito, convertido para Chicago independente do fuso original da
API. Filtrado por `status_type_completed = 'true'`.

**NHL (Blackhawks, United Center, distrito 12 — dividido com o Bulls).** O
schema muda em 2010 (`date`/`home_name`/`home_final_score` vs.
`game_date`/`home_team_name`/`home_score`), tratado com duas extrações
separadas, discriminadas pelo campo `fonte`. Nenhuma das duas variantes traz
horário de início.

---

## Limitações conhecidas

- **Coordenada validada por caixa retangular, não pelo polígono oficial da
  cidade.** Uma caixa aproximada aceita pontos de cidades vizinhas (Cicero,
  Evanston) que caem dentro do retângulo, e pode rejeitar pontos legítimos
  perto de uma borda irregular da cidade. Suficiente para descartar erros
  grosseiros de coordenada; não é uma verificação geográfica exata.
- **Granularidade temporal fica só em dia**, não em hora, mesmo o crime tendo
  `hora_ocorrencia` disponível — decisão consciente, para evitar depender de
  precisão de horário que a própria documentação oficial do Chicago Crime
  adverte não poder garantir.
- **`beat → distrito` usa a moda histórica de todo o período (2001–2026).**
  Limites de distrito já mudaram nesse intervalo; o impacto medido (42
  registros) foi considerado desprezível e não tratado.
- **`descricao_crime` é uma subcategoria controlada da fonte, não texto
  livre** — decisão consciente de não aplicar embeddings sobre ela (ver
  `03_analises_qualidade.sql`, seção 9): o campo tem cardinalidade finita e
  cada valor sempre significa exatamente a mesma coisa, então uma variável
  categórica agregada é mais direta e mais interpretável do que um vetor
  semântico nesse caso.
