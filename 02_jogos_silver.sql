-- =============================================================================
-- 02_jogos_silver.sql
-- -----------------------------------------------------------------------------
-- Constrói a camada Silver de jogos a partir da Bronze (tb_jogos_bronze), que
-- guarda o registro cru de cada liga (NFL, MLB, NBA, NHL) numa coluna JSON
-- chamada `registro`.
--
-- O que este script faz, em ordem:
--   1. Cria a dimensão estádio -> distrito policial (Bulls e Blackhawks dividem
--      o United Center, logo dividem também o mesmo distrito).
--   2. Para cada liga, extrai do JSON bruto um schema comum: id do jogo, data,
--      horário de início em fuso de Chicago, time da casa, adversário,
--      placares e resultado - filtrando SEMPRE só jogos em que o time de
--      Chicago joga EM CASA (é isso que gera concentração de gente na cidade;
--      jogos fora, como Bears em Detroit, são descartados).
--   3. Une as 5 linhas de times com UNION ALL e junta com a dimensão de
--      distrito.
--
-- Decisões de mineração de dados e por quê (resumo - ver README.md para o
-- raciocínio completo):
--   - NFL: o campo `gametime` vem em horário do Leste dos EUA (Eastern), não
--     de Chicago, mesmo para jogos em casa do Bears - convertido explicitamente.
--   - MLB: `gameDate` vem com sufixo Z (UTC real) - convertido para Chicago.
--     Excluídos jogos de Spring Training (jogados no Arizona, fora de Chicago)
--     via filtro de game_type, e jogos não finalizados via status_code.
--   - NBA: `game_date_time` já vem com offset explícito - convertido para
--     Chicago independente de qual fuso a API usava internamente.
--   - NHL: o schema muda em 2010 (campos antigos vs. novos), tratado com duas
--     CTEs discriminadas pelo campo `fonte`. Nenhuma das duas variantes traz
--     horário de início - fica NULL para os jogos do Blackhawks.
--   - Jogos futuros (ainda não disputados) são excluídos por data
--     (data_jogo < CURRENT_DATE()), não por placar nulo - mais robusto, cobre
--     também jogos cancelados/adiados sem placar.
--   - Colunas `estadio` e `tem_horario_confiabel` foram avaliadas e removidas
--     do resultado final por serem redundantes (estadio é 1:1 com time_casa;
--     confiabilidade do horário já é visível pelo NULL em horario_inicio_chicago).
-- =============================================================================

-- Dimensão auxiliar: time da casa -> estádio e distrito policial
CREATE OR REPLACE TABLE `pdm-crimes-chicago.crimes_chicago.dim_estadio_distrito` AS
SELECT * FROM UNNEST([
  STRUCT('Bulls'      AS time_casa, 'United Center'         AS estadio, 12 AS distrito_policial, 'Near West' AS nome_distrito),
  STRUCT('Blackhawks' AS time_casa, 'United Center'         AS estadio, 12 AS distrito_policial, 'Near West' AS nome_distrito),
  STRUCT('Cubs'       AS time_casa, 'Wrigley Field'         AS estadio, 19 AS distrito_policial, 'Town Hall' AS nome_distrito),
  STRUCT('White Sox'  AS time_casa, 'Guaranteed Rate Field' AS estadio, 9  AS distrito_policial, 'Deering'   AS nome_distrito),
  STRUCT('Bears'      AS time_casa, 'Soldier Field'         AS estadio, 1  AS distrito_policial, 'Central'   AS nome_distrito)
]);

-- Camada Silver de jogos
CREATE OR REPLACE TABLE `pdm-crimes-chicago.crimes_chicago.tb_jogos_silver_igor` AS

WITH nfl AS (
  SELECT
    id_jogo, liga, temporada,
    DATE(JSON_VALUE(registro, '$.gameday')) AS data_jogo,
    DATETIME(
      TIMESTAMP(
        DATETIME(DATE(JSON_VALUE(registro, '$.gameday')), PARSE_TIME('%H:%M', JSON_VALUE(registro, '$.gametime'))),
        'America/New_York'   -- gametime da NFL é Eastern, não Chicago
      ),
      'America/Chicago'
    ) AS horario_inicio_chicago,
    'Bears' AS time_casa,
    JSON_VALUE(registro, '$.away_team') AS adversario,
    CAST(JSON_VALUE(registro, '$.home_score') AS FLOAT64) AS placar_casa,
    CAST(JSON_VALUE(registro, '$.away_score') AS FLOAT64) AS placar_visitante
  FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
  WHERE liga = 'NFL'
    AND JSON_VALUE(registro, '$.home_team') = 'CHI'
    AND DATE(JSON_VALUE(registro, '$.gameday')) < CURRENT_DATE()
),

mlb_bruto AS (
  SELECT
    id_jogo, liga, temporada,
    DATE(JSON_VALUE(registro, '$.officialDate')) AS data_jogo,
    DATETIME(TIMESTAMP(JSON_VALUE(registro, '$.gameDate')), 'America/Chicago') AS horario_inicio_chicago,
    JSON_VALUE(registro, '$.teams.home.team.name') AS time_casa_bruto,
    JSON_VALUE(registro, '$.teams.away.team.name') AS adversario,
    CAST(JSON_VALUE(registro, '$.teams.home.score') AS FLOAT64) AS placar_casa,
    CAST(JSON_VALUE(registro, '$.teams.away.score') AS FLOAT64) AS placar_visitante,
    JSON_VALUE(registro, '$.gameType') AS game_type,
    JSON_VALUE(registro, '$.status.codedGameState') AS status_code
  FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
  WHERE liga = 'MLB'
    AND JSON_VALUE(registro, '$.teams.home.team.name') IN ('Chicago Cubs', 'Chicago White Sox')
),
mlb AS (
  SELECT
    id_jogo, liga, temporada, data_jogo, horario_inicio_chicago,
    CASE time_casa_bruto WHEN 'Chicago Cubs' THEN 'Cubs' WHEN 'Chicago White Sox' THEN 'White Sox' END AS time_casa,
    adversario, placar_casa, placar_visitante
  FROM mlb_bruto
  WHERE game_type IN ('R','F','D','L','W')   -- exclui Spring Training ('S')
    AND status_code = 'F'                    -- só jogos finalizados
),

nba AS (
  SELECT
    id_jogo, liga, temporada,
    DATE(JSON_VALUE(registro, '$.game_date')) AS data_jogo,
    DATETIME(TIMESTAMP(JSON_VALUE(registro, '$.game_date_time')), 'America/Chicago') AS horario_inicio_chicago,
    'Bulls' AS time_casa,
    JSON_VALUE(registro, '$.away_display_name') AS adversario,
    CAST(JSON_VALUE(registro, '$.home_score') AS FLOAT64) AS placar_casa,
    CAST(JSON_VALUE(registro, '$.away_score') AS FLOAT64) AS placar_visitante
  FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
  WHERE liga = 'NBA'
    AND JSON_VALUE(registro, '$.home_name') = 'Bulls'
    AND JSON_VALUE(registro, '$.status_type_completed') = 'true'
),

-- NHL até 2009: date, home_name, away_name, home_final_score, away_final_score
nhl_antigo AS (
  SELECT
    id_jogo, liga, temporada,
    DATE(JSON_VALUE(registro, '$.date')) AS data_jogo,
    CAST(NULL AS DATETIME) AS horario_inicio_chicago,
    'Blackhawks' AS time_casa,
    JSON_VALUE(registro, '$.away_name') AS adversario,
    CAST(JSON_VALUE(registro, '$.home_final_score') AS FLOAT64) AS placar_casa,
    CAST(JSON_VALUE(registro, '$.away_final_score') AS FLOAT64) AS placar_visitante
  FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
  WHERE liga = 'NHL'
    AND fonte = 'fastRhockey-antigo'
    AND JSON_VALUE(registro, '$.home_name') = 'Chicago Blackhawks'
),

-- NHL 2010+: game_date, home_team_name, away_team_name, home_score, away_score
nhl_novo AS (
  SELECT
    id_jogo, liga, temporada,
    DATE(JSON_VALUE(registro, '$.game_date')) AS data_jogo,
    CAST(NULL AS DATETIME) AS horario_inicio_chicago,
    'Blackhawks' AS time_casa,
    JSON_VALUE(registro, '$.away_team_name') AS adversario,
    CAST(JSON_VALUE(registro, '$.home_score') AS FLOAT64) AS placar_casa,
    CAST(JSON_VALUE(registro, '$.away_score') AS FLOAT64) AS placar_visitante
  FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
  WHERE liga = 'NHL'
    AND fonte = 'fastRhockey-novo'
    AND JSON_VALUE(registro, '$.home_team_name') = 'Chicago Blackhawks'
),

unificado AS (
  SELECT * FROM nfl        UNION ALL
  SELECT * FROM mlb        UNION ALL
  SELECT * FROM nba        UNION ALL
  SELECT * FROM nhl_antigo UNION ALL
  SELECT * FROM nhl_novo
)

SELECT
  u.id_jogo, u.liga, u.temporada, u.data_jogo, u.horario_inicio_chicago,
  u.time_casa, d.distrito_policial,
  u.adversario, u.placar_casa, u.placar_visitante,
  (u.placar_casa > u.placar_visitante) AS vitoria_casa
FROM unificado u
LEFT JOIN `pdm-crimes-chicago.crimes_chicago.dim_estadio_distrito` d USING (time_casa)
WHERE u.data_jogo IS NOT NULL
  AND u.data_jogo < CURRENT_DATE();
