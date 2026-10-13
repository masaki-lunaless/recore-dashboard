# recore-dashboard（買取共通ダッシュボード）

店舗（MOOV）と EC・宅配（RECORE）に分かれている買取データを1か所に集め、経営層と店長が同じダッシュボードを見られるようにする。

## 構成

```
[RECORE API] ──GAS（30分ごと・差分）──┐
                                       ├─→ BigQuery ─→ 集計ビュー ─→ Looker Studio
[MOOV CSV]   ──Drive──GAS（予定）───────┘    raw_*        mart_*
                                       ↑
                         マスタ用スプレッドシート（店舗・カテゴリ・閲覧権限）
```

- **データの保存と集計は BigQuery に寄せる**。スプレッドシートには明細を置かない（重くなる原因）
- **GAS は取り込みだけ**を担当する。BigQuery への書き込みは load job（無料）を使う
- **個人情報は BigQuery に持ち込まない**。氏名・住所・電話・メール・口座・自由記述・添付は GAS 側で除去し、生年月日は生まれ年だけ残す。名寄せには `member_id` を使う

| ディレクトリ | 中身 |
|---|---|
| `bigquery/01_tables.sql` | データセットとテーブル |
| `bigquery/02_views.sql` | 展開・共通化・集計のビュー |
| `gas/` | Apps Script 一式（RECORE 取り込み・マスタ同期・初期設定） |
| `index.html` / `login.html` | 旧版（ブラウザから直接 API を叩く試作）。新構成では使わない |

## セットアップ

### 1. BigQuery
1. GCP コンソールでプロジェクトを選び、BigQuery API を有効にする
2. BigQuery のクエリエディタで `bigquery/01_tables.sql` → `bigquery/02_views.sql` の順に実行

### 2. Apps Script
1. 新しい Apps Script プロジェクトを作成し、`gas/` のファイルをすべて貼り付ける
   - `appsscript.json` は「プロジェクトの設定 → 『appsscript.json』マニフェスト ファイルをエディタで表示する」にチェックを入れると編集できる
2. 「プロジェクトの設定 → Google Cloud Platform（GCP）プロジェクト」で、BigQuery と同じプロジェクト番号に切り替える
3. スクリプトプロパティを登録

   | キー | 値 |
   |---|---|
   | `RECORE_API_KEY` | RECORE の API キー（必須） |
   | `GCP_PROJECT_ID` | BigQuery のプロジェクト ID（必須） |
   | `BACKFILL_FROM` | 初回取り込みの開始日時。例 `2024-01-01 00:00:00` |
   | `ALERT_EMAIL` | エラー通知先 |
   | `BQ_DATASET` / `BQ_LOCATION` | 省略時 `kaitori` / `asia-northeast1` |

4. エディタから順に実行
   1. `testConnection` … API キーとスコープの確認（`bad_case:index` `bas_case:index` `product:index` が必要）
   2. `setupMasterSheet` … マスタ用スプレッドシートを作成（URL がログに出る）
   3. `syncRecore` … 初回取り込み。1回4.5分で区切り、続きは次回の実行で取る
   4. `installTriggers` … 定期実行を登録（RECORE 30分ごと、マスタ毎朝5時）

   初回は過去分の取り込みに数回かかる。`printSyncState` で進み具合を確認できる（`run_to_*` が消えていれば最新まで取り終えた状態）

### 3. マスタを埋める
初回取り込みの後に実行し、ログの一覧を見ながらシートを埋めて `syncMasters` を実行する。

- `printRecoreStores` → **店舗マスタ**：RECORE の店舗 ID を共通の店舗コードにひもづける
- `printRecoreCategories` → **カテゴリ対応**：RECORE の最上位カテゴリ名を共通カテゴリにそろえる
- **閲覧権限**：経営層は `ALL`、店長は `STORE` と店舗コード

### 4. Looker Studio
データソースは BigQuery の `mart_daily_store`（件数・金額・成約率）と `mart_daily_category`（カテゴリ構成・想定粗利）。

店長に自店だけを見せる場合は、データソースを「カスタムクエリ」で作り、閲覧者のメールで絞る。

```sql
SELECT m.*
FROM `PROJECT_ID.kaitori.mart_daily_store` AS m
WHERE m.store_code IN (
  SELECT store_code FROM `PROJECT_ID.kaitori.v_access_store`
  WHERE email = LOWER(@DS_USER_EMAIL)
)
```

- 成約率 = `SUM(completed_of_assessed) / SUM(assessed_cases)`
- 平均買取単価 = `SUM(buy_amount) / SUM(completed_cases)`
- 全店の順位を店長にも見せるなら、絞り込みをしないデータソースを別に用意する

## 指標の定義

| 項目 | 宅配（bad） | 店頭（bas） |
|---|---|---|
| 成約 | ステータスが `STOCKED` か `PAID` | ステータスが `DONE` |
| 成約日 | 入庫日（`stocked_at`） | 完了日（`done_at`） |
| 査定した（成約率の分母） | 査定日時がある | `ASSESSED` `CONFIRMED` `DONE` `CANCELED` |
| 成約率の基準日 | 査定日 | 来店日（作成日） |

- 明細金額 `line_total` = (買取単価 + 調整単価) × 数量 + 小計調整
- 想定粗利 = 販売単価 × 数量 − `line_total`

## 実データで確認すること
- [ ] `chk_recore_totals` が0件になるか（ケース合計と明細合計の一致。クーポン調整と税込/税抜の扱いを確定させる）
- [ ] `category.ancestors` の並び順（最上位 → 親 の想定）
- [ ] ブランドがどの商品属性に入っているか（分かれば `dim_recore_product` に列を足す）
- [ ] RECORE 側で削除されたケースの扱い（現状は最後に取った状態のまま残る）

## 今後
- MOOV の CSV 取り込み（列構成を確認してから `fct_kaitori_cases` / `fct_kaitori_lines` に `UNION ALL`）
- 店舗ごとの月次目標マスタと達成率
