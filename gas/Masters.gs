/**
 * マスタ（スプレッドシート → BigQuery）
 * 現場が編集するのはこのシートだけ。BigQuery側は毎回洗い替え
 */

const MASTER_DEFS = [
  {
    sheet: '店舗マスタ',
    table: 'm_store',
    columns: [
      ['システム', 'source_system'],     // RECORE / MOOV
      ['元店舗キー', 'source_store_key'], // RECOREは店舗ID、MOOVはCSV上の店舗コード
      ['店舗コード', 'store_code'],       // 共通コード（自由に決めてよい）
      ['店舗名', 'store_name'],
      ['エリア', 'area'],
    ],
  },
  {
    sheet: 'カテゴリ対応',
    table: 'm_category',
    columns: [
      ['システム', 'source_system'],
      ['元カテゴリ', 'source_category_key'], // RECOREは最上位カテゴリ名
      ['大カテゴリ', 'category_l1'],
      ['中カテゴリ', 'category_l2'],
    ],
  },
  {
    sheet: '閲覧権限',
    table: 'm_access',
    columns: [
      ['メールアドレス', 'email'],
      ['権限', 'role'], // ALL / STORE
      ['店舗コード', 'store_code'],
    ],
  },
];

/** トリガーから呼ぶ入口 */
function syncMasters() {
  const cfg = getConfig_();
  if (!cfg.masterSheetId) throw new Error('MASTER_SHEET_ID が未設定です。先に setupMasterSheet を実行してください');
  try {
    const ss = SpreadsheetApp.openById(cfg.masterSheetId);
    MASTER_DEFS.forEach((def) => {
      const sh = ss.getSheetByName(def.sheet);
      if (!sh) throw new Error('シート「' + def.sheet + '」がありません');
      const values = sh.getDataRange().getDisplayValues();
      const header = values[0].map((h) => String(h).trim());
      const idx = def.columns.map(([label]) => {
        const i = header.indexOf(label);
        if (i < 0) throw new Error('シート「' + def.sheet + '」に列「' + label + '」がありません');
        return i;
      });
      const rows = values.slice(1)
        .filter((r) => idx.some((i) => String(r[i]).trim() !== ''))
        .map((r) => {
          const o = {};
          def.columns.forEach(([, col], n) => { o[col] = String(r[idx[n]]).trim() || null; });
          return o;
        });

      if (rows.length) {
        const schema = def.columns.map(([, col]) => ({ name: col, type: 'STRING' }));
        bqLoadRows_(def.table, rows, { truncate: true, schema: schema });
      } else {
        bqQuery_('TRUNCATE TABLE ' + bqTable_(def.table));
      }
      console.log(def.sheet + ': ' + rows.length + '行');
    });
  } catch (e) {
    notifyError_('syncMasters', e);
    throw e;
  }
}

/** マスタ用スプレッドシートを作成（既にあれば足りないシートだけ追加） */
function setupMasterSheet() {
  const props = PropertiesService.getScriptProperties();
  let id = props.getProperty('MASTER_SHEET_ID');
  const ss = id ? SpreadsheetApp.openById(id) : SpreadsheetApp.create('買取ダッシュボード_マスタ');
  if (!id) props.setProperty('MASTER_SHEET_ID', ss.getId());

  MASTER_DEFS.forEach((def) => {
    let sh = ss.getSheetByName(def.sheet);
    if (sh) return;
    sh = ss.insertSheet(def.sheet);
    sh.getRange(1, 1, 1, def.columns.length).setValues([def.columns.map(([label]) => label)]).setFontWeight('bold');
    sh.setFrozenRows(1);
  });
  const blank = ss.getSheetByName('シート1') || ss.getSheetByName('Sheet1');
  if (blank && ss.getSheets().length > 1) ss.deleteSheet(blank);

  const rule = (list) => SpreadsheetApp.newDataValidation().requireValueInList(list, true).build();
  ss.getSheetByName('店舗マスタ').getRange('A2:A').setDataValidation(rule(['RECORE', 'MOOV']));
  ss.getSheetByName('カテゴリ対応').getRange('A2:A').setDataValidation(rule(['RECORE', 'MOOV']));
  ss.getSheetByName('閲覧権限').getRange('B2:B').setDataValidation(rule(['ALL', 'STORE']));

  console.log('マスタ: ' + ss.getUrl());
}
