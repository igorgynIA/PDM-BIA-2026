-- =============================================================================
-- 03_analises_qualidade.sql
-- -----------------------------------------------------------------------------
-- Consultas de apoio, exploração e validação usadas para embasar as decisões
-- de mineração de dados tomadas nos scripts 01 e 02. Não criam nenhuma tabela
-- nova (exceto onde indicado) - são consultas de diagnóstico, para rodar e
-- inspecionar o resultado manualmente. Cada bloco é independente.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1) Validação do fuso horário do campo `date` da tabela de crimes.
--    Objetivo: confirmar empiricamente se o campo já está em horário local de
--    Chicago (não deveria precisar de conversão) checando se a distribuição de
--    crimes por hora bate com o padrão criminológico esperado (baixa de
--    madrugada, pico à noite). Resultado obtido: padrão bate, campo já é local.
-- -----------------------------------------------------------------------------
SELECT EXTRACT(HOUR FROM date) AS hora, COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
GROUP BY hora
ORDER BY hora;


-- -----------------------------------------------------------------------------
-- 2) Beats que aparecem associados a mais de um distrito ao longo do histórico.
--    Objetivo: medir o risco de a dim_beat_distrito recuperar o distrito errado
--    para algum registro. Resultado obtido: existe ambiguidade em alguns beats,
--    mas o impacto real (consulta 3) é de apenas 42 registros - não tratado.
-- -----------------------------------------------------------------------------
SELECT
  beat,
  COUNT(DISTINCT district) AS distritos_diferentes,
  ARRAY_AGG(DISTINCT district ORDER BY district) AS quais
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
WHERE beat IS NOT NULL AND district IS NOT NULL
GROUP BY beat
HAVING distritos_diferentes > 1
ORDER BY distritos_diferentes DESC;

-- Quantos registros com distrito NULO dependem de um desses beats ambíguos
-- para a recuperação (é esse número, não o da consulta acima, que importa)
WITH beats_ambiguos AS (
  SELECT beat
  FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
  WHERE beat IS NOT NULL AND district IS NOT NULL
  GROUP BY beat
  HAVING COUNT(DISTINCT district) > 1
)
SELECT COUNT(*) AS registros_recuperados_com_beat_ambiguo
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze` b
JOIN beats_ambiguos a USING (beat)
WHERE b.district IS NULL;


-- -----------------------------------------------------------------------------
-- 3) Grupos de registros com mesmo case_number + date + block + iucr.
--    Objetivo: diferenciar duplicata real de ingestão de comportamento legítimo
--    da fonte (uma linha por vítima em homicídio). Resultado obtido: 100% dos
--    grupos são de HOMICIDE, média de 2,2 registros por grupo - comportamento
--    esperado e documentado, nenhuma deduplicação extra foi necessária.
-- -----------------------------------------------------------------------------
WITH grupos_duplicados AS (
  SELECT case_number, date, block, iucr, primary_type,
    COUNT(*) AS tamanho_grupo
  FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
  GROUP BY case_number, date, block, iucr, primary_type
  HAVING tamanho_grupo > 1
)
SELECT
  primary_type,
  COUNT(*) AS qtd_grupos,
  SUM(tamanho_grupo) AS registros_envolvidos,
  ROUND(AVG(tamanho_grupo), 1) AS tamanho_medio_grupo
FROM grupos_duplicados
GROUP BY primary_type
ORDER BY registros_envolvidos DESC;


-- -----------------------------------------------------------------------------
-- 4) Outliers de coordenada: quantos registros ficam fora da caixa
--    delimitadora aproximada da cidade, e quantos já vinham sem coordenada.
--    Rodar depois de criar a tb_crimes_silver, para conferir o resultado final.
-- -----------------------------------------------------------------------------
SELECT
  COUNTIF(latitude IS NULL AND longitude IS NULL) AS sem_coordenada,
  COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver`;


-- -----------------------------------------------------------------------------
-- 5) Auditoria geral de NULL em tb_crimes_silver, coluna a coluna.
-- -----------------------------------------------------------------------------
SELECT
  COUNTIF(unique_key IS NULL)              AS null_unique_key,
  COUNTIF(data_hora_local_chicago IS NULL) AS null_data_hora,
  COUNTIF(distrito_policial IS NULL)       AS null_distrito,   -- esperado: 0
  COUNTIF(beat IS NULL)                    AS null_beat,
  COUNTIF(tipo_crime IS NULL)              AS null_tipo_crime,
  COUNTIF(descricao_crime IS NULL)         AS null_descricao,
  COUNTIF(local_ocorrencia IS NULL)        AS null_local_ocorrencia,
  COUNTIF(houve_prisao IS NULL)            AS null_prisao,
  COUNTIF(eh_domestico IS NULL)            AS null_domestico,
  COUNTIF(latitude IS NULL)                AS null_latitude,
  COUNTIF(longitude IS NULL)               AS null_longitude,
  COUNTIF(ano IS NULL)                     AS null_ano,
  COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver`;


-- -----------------------------------------------------------------------------
-- 6) Auditoria geral de NULL em tb_jogos_silver_igor, coluna a coluna.
-- -----------------------------------------------------------------------------
SELECT
  COUNTIF(id_jogo IS NULL)                AS null_id_jogo,
  COUNTIF(liga IS NULL)                   AS null_liga,
  COUNTIF(temporada IS NULL)              AS null_temporada,
  COUNTIF(data_jogo IS NULL)              AS null_data_jogo,
  COUNTIF(horario_inicio_chicago IS NULL) AS null_horario,   -- esperado: só NHL
  COUNTIF(time_casa IS NULL)              AS null_time_casa,
  COUNTIF(distrito_policial IS NULL)      AS null_distrito,  -- esperado: 0
  COUNTIF(adversario IS NULL)             AS null_adversario,
  COUNTIF(placar_casa IS NULL)            AS null_placar_casa,
  COUNTIF(placar_visitante IS NULL)       AS null_placar_visitante,
  COUNTIF(vitoria_casa IS NULL)           AS null_vitoria_casa,
  COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_silver_igor`;


-- -----------------------------------------------------------------------------
-- 7) Validação de contagem de jogos por time/liga, comparada contra a
--    história real dos times (Bulls ~41 em casa/temporada, Bears 228 em casa
--    no total até a data de corte, Cubs/White Sox ~200/temporada,
--    Blackhawks 41 em casa/temporada + anos de playoff maiores).
-- -----------------------------------------------------------------------------
SELECT
  liga, time_casa,
  COUNT(*) AS total_jogos,
  MIN(data_jogo) AS primeiro_jogo,
  MAX(data_jogo) AS ultimo_jogo,
  COUNTIF(horario_inicio_chicago IS NOT NULL) AS com_horario,
  COUNTIF(distrito_policial IS NULL) AS sem_distrito_mapeado
FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_silver_igor`
GROUP BY liga, time_casa
ORDER BY liga, time_casa;


-- -----------------------------------------------------------------------------
-- 8) Diagnóstico de jogos com game_type != 'REG' na NFL (checagem de possível
--    pré-temporada escondida, análoga ao Spring Training do MLB).
--    Resultado obtido: não existe 'PRE' (nem qualquer outro tipo) nos dados.
-- -----------------------------------------------------------------------------
SELECT DISTINCT JSON_VALUE(registro, '$.game_type')
FROM `pdm-crimes-chicago.crimes_chicago.tb_jogos_bronze`
WHERE liga = 'NFL';


-- -----------------------------------------------------------------------------
-- 9) Exploração de descricao_crime: quantos valores distintos existem e como
--    se relacionam com tipo_crime (primary_type). Usado para decidir que
--    description é uma subcategoria controlada (não texto livre) e por isso
--    não é candidata a embeddings - ver README.md.
-- -----------------------------------------------------------------------------
SELECT descricao_crime, COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver`
GROUP BY descricao_crime
ORDER BY total DESC
LIMIT 30;

SELECT
  tipo_crime,
  COUNT(DISTINCT descricao_crime) AS qtd_descricoes_distintas,
  COUNT(*) AS total_ocorrencias
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver`
GROUP BY tipo_crime
ORDER BY total_ocorrencias DESC;


-- -----------------------------------------------------------------------------
-- 10) Exploração de local_ocorrencia (location_description), em especial à
--     procura de um valor relacionado a estádio/arena esportiva - candidato a
--     feature futura na Gold (crime especificamente no/perto do local do jogo).
-- -----------------------------------------------------------------------------
SELECT local_ocorrencia, COUNT(*) AS total
FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver`
GROUP BY local_ocorrencia
ORDER BY total DESC
LIMIT 40;
