-- =====================================================================
-- 買取共通ダッシュボード: テーブル定義
-- BigQueryコンソールで、対象プロジェクトを選んだ状態で実行する
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS kaitori
OPTIONS (location = 'asia-northeast1', description = '買取共通ダッシュボード');

-- ---------------------------------------------------------------------
-- RAW: RECOREのケースをAPIレスポンスのまま追記していく（個人情報はGAS側で除去済み）
-- 同じケースが更新のたびに複数行入る。最新行はビュー側で選ぶ
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kaitori.raw_recore_cases (
  source      STRING    NOT NULL OPTIONS (description = 'bad=宅配買取 / bas=店頭買取 / big=一般仕入'),
  case_id     INT64     NOT NULL,
  updated_at  TIMESTAMP          OPTIONS (description = 'RECORE側の更新日時'),
  payload     STRING             OPTIONS (description = 'ケースJSON（個人情報除去済み）'),
  ingested_at TIMESTAMP NOT NULL
)
PARTITION BY DATE(ingested_at)
CLUSTER BY source, case_id;

CREATE TABLE IF NOT EXISTS kaitori.raw_recore_products (
  product_id  INT64     NOT NULL,
  updated_at  TIMESTAMP,
  payload     STRING,
  ingested_at TIMESTAMP NOT NULL
)
PARTITION BY DATE(ingested_at)
CLUSTER BY product_id;

-- ---------------------------------------------------------------------
-- MASTER: スプレッドシートから GAS（syncMasters）で毎日洗い替え
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS kaitori.m_store (
  source_system    STRING OPTIONS (description = 'RECORE / MOOV'),
  source_store_key STRING OPTIONS (description = 'RECOREは店舗ID、MOOVはCSV上の店舗コード'),
  store_code       STRING OPTIONS (description = '共通店舗コード'),
  store_name       STRING,
  area             STRING
);

CREATE TABLE IF NOT EXISTS kaitori.m_category (
  source_system       STRING OPTIONS (description = 'RECORE / MOOV'),
  source_category_key STRING OPTIONS (description = 'RECOREは最上位カテゴリ名、MOOVはCSV上の分類'),
  category_l1         STRING OPTIONS (description = '共通カテゴリ（大）'),
  category_l2         STRING OPTIONS (description = '共通カテゴリ（中）')
);

CREATE TABLE IF NOT EXISTS kaitori.m_access (
  email      STRING,
  role       STRING OPTIONS (description = 'ALL=全店 / STORE=自店のみ'),
  store_code STRING
);
