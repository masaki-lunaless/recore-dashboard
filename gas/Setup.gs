/**
 * 初期設定・運用用の関数（エディタから手動で実行する）
 */

/** APIキーの疎通とスコープを確認 */
function testConnection() {
  const res = recoreGet_('/me', {});
  console.log(JSON.stringify(res.body, null, 2));
}

/** 定期実行トリガーを登録（RECORE: 30分ごと / マスタ: 毎朝5時） */
function installTriggers() {
  const handlers = ['syncRecore', 'syncMasters'];
  ScriptApp.getProjectTriggers()
    .filter((t) => handlers.indexOf(t.getHandlerFunction()) >= 0)
    .forEach((t) => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncRecore').timeBased().everyMinutes(30).create();
  ScriptApp.newTrigger('syncMasters').timeBased().atHour(5).everyDays(1).create();
  console.log('トリガーを登録しました');
}

/** 店舗マスタを埋めるための一覧（取り込み後に実行） */
function printRecoreStores() {
  bqQuery_(
    'SELECT source, recore_store_id, ANY_VALUE(recore_store_name), COUNT(*) FROM ' + bqTable_('stg_recore_cases') +
    ' GROUP BY source, recore_store_id ORDER BY source, recore_store_id'
  ).forEach((r) => console.log(r.join('\t')));
}

/** カテゴリ対応を埋めるための一覧（取り込み後に実行） */
function printRecoreCategories() {
  bqQuery_(
    'SELECT p.category_l1, COUNT(*) FROM ' + bqTable_('stg_recore_goods') + ' AS g ' +
    'LEFT JOIN ' + bqTable_('dim_recore_product') + ' AS p USING (product_id) GROUP BY 1 ORDER BY 2 DESC'
  ).forEach((r) => console.log(r.join('\t')));
}

/** 取り込み状況の確認 */
function printSyncState() {
  const props = PropertiesService.getScriptProperties().getProperties();
  Object.keys(props).filter((k) => /^(wm|run_to|cursor)_/.test(k)).sort()
    .forEach((k) => console.log(k + ' = ' + (k.indexOf('cursor_') === 0 ? '(あり)' : props[k])));
}

/** 指定した種別を最初から取り直す（BACKFILL_FROM から再取得。重複はビューで除外される） */
function resetSyncState(source) {
  const props = PropertiesService.getScriptProperties();
  const targets = source ? [source] : Object.keys(RECORE_SOURCES);
  targets.forEach((s) => ['wm_', 'run_to_', 'cursor_'].forEach((p) => props.deleteProperty(p + s)));
  console.log('リセット: ' + targets.join(', '));
}

function notifyError_(where, e) {
  console.error(where + ': ' + (e && e.stack || e));
  const to = PropertiesService.getScriptProperties().getProperty('ALERT_EMAIL');
  if (!to) return;
  MailApp.sendEmail(to, '[買取ダッシュボード] ' + where + ' でエラー', String(e && e.stack || e));
}
