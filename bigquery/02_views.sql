-- =====================================================================
-- 買取共通ダッシュボード: ビュー定義
-- 01_tables.sql の後に実行する。何度実行してもよい（CREATE OR REPLACE）
--
--   raw_*            … APIの生データ（追記のみ）
--   stg_*            … 最新行の抽出とJSON展開
--   fct_*            … RECORE / MOOV を共通の形にそろえたもの
--   mart_*           … Looker Studio が直接読む集計
-- =====================================================================

-- ---------------------------------------------------------------------
-- STG: ケースごとの最新行
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.stg_recore_cases_latest AS
SELECT source, case_id, payload
FROM kaitori.raw_recore_cases
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY source, case_id ORDER BY updated_at DESC, ingested_at DESC
) = 1;

CREATE OR REPLACE VIEW kaitori.stg_recore_cases AS
WITH parsed AS (
  SELECT
    source,
    case_id,
    JSON_VALUE(payload, '$.code')                                AS case_code,
    SAFE_CAST(JSON_VALUE(payload, '$.store.id') AS INT64)        AS recore_store_id,
    JSON_VALUE(payload, '$.store.name')                          AS recore_store_name,
    SAFE_CAST(JSON_VALUE(payload, '$.staff.id') AS INT64)        AS staff_id,
    JSON_VALUE(payload, '$.staff.name')                          AS staff_name,
    JSON_VALUE(payload, '$.status')                              AS status,
    SAFE_CAST(JSON_VALUE(payload, '$.member_id') AS INT64)       AS member_id,
    JSON_VALUE(payload, '$.prefecture')                          AS prefecture,
    JSON_VALUE(payload, '$.sex')                                 AS sex,
    SAFE_CAST(JSON_VALUE(payload, '$.birth_year') AS INT64)      AS birth_year,
    JSON_VALUE(payload, '$.payment.type')                        AS payment_type,
    JSON_QUERY(payload, '$.attribute')                           AS attribute_json,
    SAFE_CAST(JSON_VALUE(payload, '$.is_price_tax_incl') AS BOOL) AS is_price_tax_incl,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.offered_at')  AS INT64)) AS offered_at,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.assessed_at') AS INT64)) AS assessed_at,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.stocked_at')  AS INT64)) AS stocked_at,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.done_at')     AS INT64)) AS done_at,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.created_at')  AS INT64)) AS created_at,
    TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(payload, '$.updated_at')  AS INT64)) AS updated_at,
    SAFE_CAST(JSON_VALUE(payload, '$.summary.quantity') AS INT64)          AS total_quantity,
    SAFE_CAST(JSON_VALUE(payload, '$.summary.sub_total') AS INT64)         AS sub_total,
    SAFE_CAST(JSON_VALUE(payload, '$.summary.case_adjustment') AS INT64)   AS case_adjustment,
    SAFE_CAST(JSON_VALUE(payload, '$.summary.coupon_adjustment') AS INT64) AS coupon_adjustment,
    SAFE_CAST(JSON_VALUE(payload, '$.summary.total') AS INT64)             AS total_amount
  FROM kaitori.stg_recore_cases_latest
)
SELECT
  *,
  -- 成約（買取完了）の判定
  CASE source
    WHEN 'bad' THEN status IN ('STOCKED', 'PAID')
    ELSE status = 'DONE'
  END AS is_completed,
  -- 成約率の分母になる「査定した」ケース
  CASE source
    WHEN 'bad' THEN assessed_at IS NOT NULL
    WHEN 'bas' THEN status IN ('ASSESSED', 'CONFIRMED', 'DONE', 'CANCELED')
    ELSE TRUE  -- 一般仕入は査定の概念がない
  END AS is_assessed,
  -- 買取完了日時（宅配は入庫日時、それ以外は完了日時）
  CASE source WHEN 'bad' THEN stocked_at ELSE done_at END AS completed_at,
  -- 成約率を集計する基準日時（宅配は査定日時、店頭は来店＝作成日時）
  CASE source WHEN 'bad' THEN assessed_at ELSE created_at END AS base_at
FROM parsed;

CREATE OR REPLACE VIEW kaitori.stg_recore_goods AS
SELECT
  l.source,
  l.case_id,
  SAFE_CAST(JSON_VALUE(g, '$.id') AS INT64)                   AS goods_id,
  SAFE_CAST(JSON_VALUE(g, '$.serial') AS INT64)               AS serial,
  SAFE_CAST(JSON_VALUE(g, '$.product_id') AS INT64)           AS product_id,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.is_canceled') AS BOOL), FALSE) AS is_canceled,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.quantity') AS INT64), 0)  AS quantity,
  JSON_VALUE(g, '$.grade.name')                               AS grade_name,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.unit_price') AS INT64), 0)         AS unit_price,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.unit_adjustment') AS INT64), 0)    AS unit_adjustment,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.selling_unit_price') AS INT64), 0) AS selling_unit_price,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.case_adjustment') AS INT64), 0)    AS case_adjustment,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.coupon_adjustment') AS INT64), 0)  AS coupon_adjustment,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.tax') AS INT64), 0)                AS tax,
  IFNULL(SAFE_CAST(JSON_VALUE(g, '$.included_tax') AS INT64), 0)       AS included_tax,
  SAFE_CAST(JSON_VALUE(g, '$.item_id') AS INT64)              AS item_id
FROM kaitori.stg_recore_cases_latest AS l,
  UNNEST(JSON_QUERY_ARRAY(l.payload, '$.goods')) AS g;

-- ---------------------------------------------------------------------
-- DIM: 商品（カテゴリ階層つき）
-- category.ancestors は 最上位 → 親 の順と想定（実データで要確認）
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.dim_recore_product AS
WITH latest AS (
  SELECT product_id, payload
  FROM kaitori.raw_recore_products
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY product_id ORDER BY updated_at DESC, ingested_at DESC
  ) = 1
),
parsed AS (
  SELECT
    product_id,
    JSON_VALUE(payload, '$.code')                            AS product_code,
    JSON_VALUE(payload, '$.title')                           AS title,
    SAFE_CAST(JSON_VALUE(payload, '$.category.id') AS INT64) AS category_id,
    JSON_VALUE(payload, '$.category.name')                   AS category_name,
    ARRAY(
      SELECT JSON_VALUE(a, '$.name')
      FROM UNNEST(JSON_QUERY_ARRAY(payload, '$.category.ancestors')) AS a WITH OFFSET AS o
      ORDER BY o
    )                                                        AS ancestor_names,
    JSON_QUERY(payload, '$.attribute')                       AS attribute_json
  FROM latest
)
SELECT
  product_id,
  product_code,
  title,
  category_id,
  category_name,
  ARRAY_TO_STRING(ARRAY_CONCAT(ancestor_names, [category_name]), ' > ') AS category_path,
  COALESCE(ancestor_names[SAFE_OFFSET(0)], category_name)               AS category_l1,
  IF(ARRAY_LENGTH(ancestor_names) = 0, NULL,
     COALESCE(ancestor_names[SAFE_OFFSET(1)], category_name))           AS category_l2,
  attribute_json
FROM parsed;

-- ---------------------------------------------------------------------
-- FCT: 共通ケース（RECORE + MOOV）
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.fct_kaitori_cases AS
WITH store_map AS (
  SELECT source_system, source_store_key,
         ANY_VALUE(store_code) AS store_code, ANY_VALUE(store_name) AS store_name
  FROM kaitori.m_store
  GROUP BY source_system, source_store_key
),
recore AS (
  SELECT
    'RECORE'                                                      AS source_system,
    c.source                                                      AS source_type,
    CASE c.source WHEN 'bad' THEN '宅配' WHEN 'bas' THEN '店頭' WHEN 'big' THEN '仕入' END AS channel,
    COALESCE(s.store_code, CONCAT('RECORE-', CAST(c.recore_store_id AS STRING))) AS store_code,
    COALESCE(s.store_name, c.recore_store_name)                   AS store_name,
    CONCAT('RECORE-', c.source, '-', CAST(c.case_id AS STRING))   AS case_key,
    c.case_code,
    c.status,
    c.is_assessed,
    c.is_completed,
    DATE(c.base_at, 'Asia/Tokyo')                                 AS base_date,
    DATE(c.completed_at, 'Asia/Tokyo')                            AS completed_date,
    c.staff_name,
    IF(c.member_id IS NULL, NULL, CONCAT('RECORE-', CAST(c.member_id AS STRING))) AS member_key,
    c.prefecture,
    c.sex,
    c.birth_year,
    c.total_quantity,
    c.total_amount
  FROM kaitori.stg_recore_cases AS c
  LEFT JOIN store_map AS s
    ON s.source_system = 'RECORE'
   AND s.source_store_key = CAST(c.recore_store_id AS STRING)
)
SELECT * FROM recore
-- TODO(MOOV): CSV受領後、同じ列構成の moov CTE を作って UNION ALL する
;

-- ---------------------------------------------------------------------
-- FCT: 共通明細
-- line_total = (買取単価 + 調整単価) × 数量 + 小計調整
-- ※ クーポン調整の扱いは chk_recore_totals で実データと突き合わせて確定させる
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.fct_kaitori_lines AS
WITH category_map AS (
  SELECT source_system, source_category_key,
         ANY_VALUE(category_l1) AS category_l1, ANY_VALUE(category_l2) AS category_l2
  FROM kaitori.m_category
  GROUP BY source_system, source_category_key
),
recore AS (
  SELECT
    c.source_system,
    c.source_type,
    c.channel,
    c.store_code,
    c.store_name,
    c.case_key,
    c.status,
    c.is_completed,
    c.base_date,
    c.completed_date,
    c.staff_name,
    c.member_key,
    CONCAT('RECORE-', CAST(g.product_id AS STRING))           AS product_key,
    p.title                                                   AS product_title,
    COALESCE(m.category_l1, p.category_l1, '未分類')          AS category_l1,
    COALESCE(m.category_l2, p.category_l2)                    AS category_l2,
    g.grade_name,
    g.is_canceled                                             AS is_line_canceled,
    g.quantity,
    (g.unit_price + g.unit_adjustment) * g.quantity           AS buy_amount,
    g.case_adjustment,
    g.coupon_adjustment,
    (g.unit_price + g.unit_adjustment) * g.quantity + g.case_adjustment AS line_total,
    g.selling_unit_price * g.quantity                         AS expected_sell_amount
  FROM kaitori.stg_recore_goods AS g
  JOIN kaitori.fct_kaitori_cases AS c
    ON c.case_key = CONCAT('RECORE-', g.source, '-', CAST(g.case_id AS STRING))
  LEFT JOIN kaitori.dim_recore_product AS p
    ON p.product_id = g.product_id
  LEFT JOIN category_map AS m
    ON m.source_system = 'RECORE' AND m.source_category_key = p.category_l1
)
SELECT * FROM recore
-- TODO(MOOV): UNION ALL
;

-- ---------------------------------------------------------------------
-- MART: 店舗×チャネル×日（件数・金額・成約率の材料）
-- 成約率は Looker Studio で SUM(completed_of_assessed) / SUM(assessed_cases)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.mart_daily_store AS
WITH done AS (
  SELECT
    completed_date AS date, store_code, store_name, channel,
    COUNT(*)            AS completed_cases,
    SUM(total_quantity) AS quantity,
    SUM(total_amount)   AS buy_amount
  FROM kaitori.fct_kaitori_cases
  WHERE is_completed AND completed_date IS NOT NULL
  GROUP BY date, store_code, store_name, channel
),
assessed AS (
  SELECT
    base_date AS date, store_code, store_name, channel,
    COUNT(*)              AS assessed_cases,
    COUNTIF(is_completed) AS completed_of_assessed
  FROM kaitori.fct_kaitori_cases
  WHERE is_assessed AND base_date IS NOT NULL
  GROUP BY date, store_code, store_name, channel
)
SELECT
  date, store_code, store_name, channel,
  IFNULL(d.completed_cases, 0)       AS completed_cases,
  IFNULL(d.quantity, 0)              AS quantity,
  IFNULL(d.buy_amount, 0)            AS buy_amount,
  IFNULL(a.assessed_cases, 0)        AS assessed_cases,
  IFNULL(a.completed_of_assessed, 0) AS completed_of_assessed
FROM done AS d
FULL OUTER JOIN assessed AS a USING (date, store_code, store_name, channel);

-- ---------------------------------------------------------------------
-- MART: 店舗×チャネル×カテゴリ×日（構成比・想定粗利）
-- 件数はカテゴリをまたぐと重複するので、件数KPIは mart_daily_store を使う
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.mart_daily_category AS
SELECT
  completed_date AS date,
  store_code,
  store_name,
  channel,
  category_l1,
  category_l2,
  SUM(quantity)                                 AS quantity,
  SUM(line_total)                               AS buy_amount,
  SUM(expected_sell_amount)                     AS expected_sell_amount,
  SUM(expected_sell_amount) - SUM(line_total)   AS expected_gross_profit
FROM kaitori.fct_kaitori_lines
WHERE is_completed AND NOT is_line_canceled AND completed_date IS NOT NULL
GROUP BY date, store_code, store_name, channel, category_l1, category_l2;

-- ---------------------------------------------------------------------
-- ACCESS: 閲覧者メール × 見てよい店舗
-- Looker Studio のカスタムクエリで @DS_USER_EMAIL と突き合わせる
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.v_access_store AS
SELECT DISTINCT LOWER(TRIM(a.email)) AS email, s.store_code
FROM kaitori.m_access AS a
JOIN (SELECT DISTINCT store_code FROM kaitori.fct_kaitori_cases) AS s
  ON UPPER(a.role) = 'ALL' OR a.store_code = s.store_code;

-- ---------------------------------------------------------------------
-- CHECK: ケース合計と明細合計のズレ（金額定義の検証用。0件になれば定義が正しい）
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW kaitori.chk_recore_totals AS
SELECT
  c.source,
  c.case_id,
  c.case_code,
  c.status,
  c.total_amount,
  c.coupon_adjustment,
  SUM(IF(g.is_canceled, 0, (g.unit_price + g.unit_adjustment) * g.quantity + g.case_adjustment)) AS lines_total
FROM kaitori.stg_recore_cases AS c
JOIN kaitori.stg_recore_goods AS g USING (source, case_id)
GROUP BY c.source, c.case_id, c.case_code, c.status, c.total_amount, c.coupon_adjustment
HAVING lines_total != c.total_amount;
