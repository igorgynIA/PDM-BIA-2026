-- =============================================================================
-- 01_crimes_silver.sql
-- -----------------------------------------------------------------------------
-- Constrói a camada Silver de crimes a partir da Bronze (tb_crimes_bronze).
--
-- O que este script faz, em ordem:
--   1. Cria uma dimensão auxiliar beat -> distrito, derivada dos próprios dados,
--      usada para recuperar o distrito policial quando ele vem nulo na Bronze.
--   2. Deduplica os registros por unique_key.
--   3. Recupera distrito ausente via beat; descarta a tupla se não for possível
--      recuperar, ou se o distrito final estiver fora do intervalo válido (1-25).
--   4. Limpa latitude/longitude: mantém o valor original quando está dentro de
--      uma caixa delimitadora aproximada da cidade de Chicago, e zera (NULL)
--      quando está fora dela ou já vinha nulo na Bronze.
--
-- Decisões de mineração de dados e por quê (resumo - ver README.md para o
-- raciocínio completo):
--   - Recuperação de distrito via beat: beat é geograficamente aninhado dentro
--     de distrito (relação N:1), tornando essa imputação segura. Verificamos
--     que apenas 42 registros de todo o histórico dependem de um beat que já
--     foi associado a mais de um distrito ao longo do tempo - impacto
--     desprezível, não tratado.
--   - Nenhuma deduplicação além de unique_key foi necessária: os poucos casos
--     de múltiplas linhas com mesmo case_number/date/block/iucr são 100%
--     homicídios (uma linha por vítima), comportamento documentado e correto
--     da fonte, não duplicata de ingestão.
--   - O campo date já foi confirmado empiricamente como horário local de
--     Chicago (distribuição por hora bate com o padrão criminológico
--     esperado), então nenhuma conversão de fuso foi aplicada.
--   - Coordenadas fora da caixa delimitadora, ou ausentes, viram NULL em vez
--     de serem descartadas ou imputadas com um valor artificial (ex: centroide
--     do distrito) - a tupla continua valendo para as métricas agregadas por
--     distrito, só não deve ser usada em mapas de ponto.
-- =============================================================================

-- Dimensão auxiliar: beat -> distrito mais frequente associado a ele
CREATE OR REPLACE TABLE `pdm-crimes-chicago.crimes_chicago.dim_beat_distrito` AS
SELECT beat, district AS distrito_policial
FROM (
  SELECT
    beat, district,
    ROW_NUMBER() OVER (PARTITION BY beat ORDER BY COUNT(*) DESC) AS rn
  FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
  WHERE beat IS NOT NULL AND district IS NOT NULL
  GROUP BY beat, district
)
WHERE rn = 1;

-- Camada Silver de crimes
CREATE OR REPLACE TABLE `pdm-crimes-chicago.crimes_chicago.tb_crimes_silver` AS

WITH dedup AS (
  SELECT *
  FROM `pdm-crimes-chicago.crimes_chicago.tb_crimes_bronze`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY unique_key ORDER BY unique_key) = 1
),
com_distrito_recuperado AS (
  SELECT
    d.*,
    COALESCE(d.district, m.distrito_policial) AS distrito_final
  FROM dedup d
  LEFT JOIN `pdm-crimes-chicago.crimes_chicago.dim_beat_distrito` m
    ON d.beat = m.beat
)

SELECT
  unique_key,
  date                                     AS data_hora_local_chicago,
  DATE(date)                               AS data_ocorrencia,
  EXTRACT(HOUR FROM date)                  AS hora_ocorrencia,        -- mantida, mas não usada na Gold
  distrito_final                           AS distrito_policial,
  beat,
  primary_type                             AS tipo_crime,
  description                              AS descricao_crime,
  location_description                     AS local_ocorrencia,
  arrest                                    AS houve_prisao,
  domestic                                  AS eh_domestico,
  -- caixa delimitadora aproximada da cidade de Chicago (não é o polígono oficial)
  IF(latitude BETWEEN 41.64 AND 42.03 AND longitude BETWEEN -87.95 AND -87.52, latitude,  NULL) AS latitude,
  IF(latitude BETWEEN 41.64 AND 42.03 AND longitude BETWEEN -87.95 AND -87.52, longitude, NULL) AS longitude,
  year                                       AS ano
FROM com_distrito_recuperado
WHERE distrito_final IS NOT NULL
  AND distrito_final BETWEEN 1 AND 25;
