/**
 * 設定
 *
 * スクリプトプロパティ（プロジェクトの設定 > スクリプト プロパティ）に以下を登録する
 *   RECORE_API_KEY   : RECOREのAPIキー（必須）
 *   GCP_PROJECT_ID   : BigQueryのプロジェクトID（必須）
 *   BQ_DATASET       : データセット名（省略時 kaitori）
 *   BQ_LOCATION      : ロケーション（省略時 asia-northeast1）
 *   MASTER_SHEET_ID  : マスタ用スプレッドシートID（setupMasterSheet で自動登録）
 *   ALERT_EMAIL      : エラー通知先（省略時は通知しない）
 *   BACKFILL_FROM    : 初回取り込みの開始日時 例) 2024-01-01 00:00:00
 */

const RECORE_BASE_URL = 'https://co-api.recore-pos.com';

// RECOREから取り込むケース種別。使わないものは enabled: false にする
const RECORE_SOURCES = {
  bad: { path: '/bad_cases',    label: '宅配買取', enabled: true },
  bas: { path: '/v2/bas_cases', label: '店頭買取', enabled: true },
  big: { path: '/big_cases',    label: '一般仕入', enabled: false },
};

// 1回の実行で使ってよい時間（GASの上限6分に対して余裕を持たせる）
const RUN_BUDGET_MS = 4.5 * 60 * 1000;
// 取りこぼし防止のため、前回の到達点から少し戻って取得する（重複はビューで除外）
const OVERLAP_MS = 10 * 60 * 1000;
// RECOREの基本制限レートは 5 rps
const REQUEST_INTERVAL_MS = 250;
const PAGE_LIMIT = 250;
// BigQueryへの書き込み単位（load job の回数を抑える）
const LOAD_BATCH_ROWS = 2000;

// BigQueryに持ち込まない項目（個人情報・自由記述・一時URL）
const CASE_DROP_KEYS = [
  'last_name', 'last_kana', 'first_name', 'first_kana',
  'postal_code', 'address1', 'address2', 'tel', 'email', 'birthdate',
  'bank_code', 'bank_branch_code', 'bank_account_number', 'bank_account_name',
  'invoice_provider_number', 'note', 'customer_note', 'offer_comment', 'buyer_comment',
  'attachments', 'calling',
];
const GOODS_DROP_KEYS = ['note', 'condition_note'];

function getConfig_() {
  const props = PropertiesService.getScriptProperties();
  const required = (key) => {
    const v = props.getProperty(key);
    if (!v) throw new Error('スクリプトプロパティ ' + key + ' が未設定です');
    return v;
  };
  return {
    apiKey: required('RECORE_API_KEY'),
    projectId: required('GCP_PROJECT_ID'),
    dataset: props.getProperty('BQ_DATASET') || 'kaitori',
    location: props.getProperty('BQ_LOCATION') || 'asia-northeast1',
    masterSheetId: props.getProperty('MASTER_SHEET_ID'),
    alertEmail: props.getProperty('ALERT_EMAIL'),
    backfillFrom: props.getProperty('BACKFILL_FROM') || '2024-01-01 00:00:00',
  };
}
