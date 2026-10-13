/**
 * RECORE → BigQuery 差分取り込み
 *
 * 更新日時（updated_at）の範囲で、カーソルページネーションを使って取得する。
 * 6分の実行制限に引っかからないよう、時間切れになったらカーソルを保存して次回に続きから取る。
 *
 * 保存する状態（スクリプトプロパティ）
 *   wm_<source>     : 取り込み済みの到達点（ISO8601）
 *   run_to_<source> : 取得中の範囲の終端（取得中のみ）
 *   cursor_<source> : 取得中のカーソル（取得中のみ）
 */

/** トリガーから呼ぶ入口 */
function syncRecore() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(10 * 1000)) {
    console.log('前回の実行が続いているためスキップ');
    return;
  }
  const startedAt = Date.now();
  try {
    Object.keys(RECORE_SOURCES).forEach((source) => {
      if (!RECORE_SOURCES[source].enabled || timeUp_(startedAt)) return;
      syncCases_(source, startedAt);
    });
    if (!timeUp_(startedAt)) syncMissingProducts_(startedAt);
  } catch (e) {
    notifyError_('syncRecore', e);
    throw e;
  } finally {
    lock.releaseLock();
  }
}

/** @return {boolean} 範囲の最後まで取り終えたら true */
function syncCases_(source, startedAt) {
  const def = RECORE_SOURCES[source];
  const cfg = getConfig_();
  const props = PropertiesService.getScriptProperties();
  const wmKey = 'wm_' + source;
  const toKey = 'run_to_' + source;
  const curKey = 'cursor_' + source;

  let runTo = props.getProperty(toKey);
  let cursor = props.getProperty(curKey) || '';
  if (!runTo) {
    runTo = new Date().toISOString();
    cursor = '';
    props.setProperty(toKey, runTo);
  }
  const wm = props.getProperty(wmKey);
  const from = wm ? new Date(new Date(wm).getTime() - OVERLAP_MS) : parseJst_(cfg.backfillFrom);

  let buffer = [];
  let loaded = 0;
  let cursorRetried = false;
  const flush = () => {
    bqLoadRows_('raw_recore_cases', buffer);
    loaded += buffer.length;
    buffer = [];
  };

  for (;;) {
    let res;
    try {
      res = recoreGet_(def.path, {
        updated_at_from: recoreDateTime_(from),
        updated_at_to: recoreDateTime_(new Date(runTo)),
        limit: PAGE_LIMIT,
        cursor: cursor,
      });
    } catch (e) {
      // 前回保存したカーソルが失効している可能性。範囲の先頭から取り直す（重複はビューで除外）
      if (cursor && !cursorRetried) {
        console.warn(def.label + ': カーソルを破棄して範囲の先頭から再取得します: ' + e.message);
        cursor = '';
        cursorRetried = true;
        continue;
      }
      throw e;
    }

    const ingestedAt = new Date().toISOString();
    res.body.forEach((c) => {
      buffer.push({
        source: source,
        case_id: c.id,
        updated_at: c.updated_at ? new Date(c.updated_at * 1000).toISOString() : null,
        payload: JSON.stringify(sanitizeCase_(c)),
        ingested_at: ingestedAt,
      });
    });

    const next = res.headers['x-next-cursor'];
    if (!next) {
      flush();
      props.setProperty(wmKey, runTo);
      props.deleteProperty(toKey);
      props.deleteProperty(curKey);
      console.log(def.label + ': ' + loaded + '件 取り込み完了（〜' + recoreDateTime_(new Date(runTo)) + '）');
      return true;
    }

    cursor = next;
    if (buffer.length >= LOAD_BATCH_ROWS || timeUp_(startedAt)) {
      flush();
      props.setProperty(curKey, cursor);
    }
    if (timeUp_(startedAt)) {
      console.log(def.label + ': ' + loaded + '件 取り込み。時間切れのため次回続きから');
      return false;
    }
  }
}

/** 明細に出てくる商品のうち、まだ取り込んでいないものを取得する */
function syncMissingProducts_(startedAt) {
  const ids = bqQuery_(
    'SELECT DISTINCT g.product_id FROM ' + bqTable_('stg_recore_goods') + ' AS g ' +
    'LEFT JOIN ' + bqTable_('raw_recore_products') + ' AS p ON p.product_id = g.product_id ' +
    'WHERE p.product_id IS NULL AND g.product_id IS NOT NULL LIMIT 5000'
  ).map((r) => Number(r[0]));
  if (!ids.length) return;

  const ingestedAt = new Date().toISOString();
  let rows = [];
  for (let i = 0; i < ids.length && !timeUp_(startedAt); i += 100) {
    const chunk = ids.slice(i, i + 100);
    const res = recoreGet_('/products', { ids: chunk.join(','), limit: PAGE_LIMIT });
    const found = {};
    res.body.forEach((p) => {
      found[p.id] = true;
      rows.push({
        product_id: p.id,
        updated_at: p.updated_at ? new Date(p.updated_at * 1000).toISOString() : null,
        payload: JSON.stringify(p),
        ingested_at: ingestedAt,
      });
    });
    // 削除済みなどで返ってこない商品は空で登録し、毎回取りに行かないようにする
    chunk.filter((id) => !found[id]).forEach((id) => {
      rows.push({ product_id: id, updated_at: null, payload: JSON.stringify({ id: id, _missing: true }), ingested_at: ingestedAt });
    });
  }
  bqLoadRows_('raw_recore_products', rows);
  console.log('商品: ' + rows.length + '件 取り込み');
}

function timeUp_(startedAt) {
  return Date.now() - startedAt > RUN_BUDGET_MS;
}

function bqTable_(name) {
  const cfg = getConfig_();
  return '`' + cfg.projectId + '.' + cfg.dataset + '.' + name + '`';
}

/** 'yyyy-MM-dd HH:mm:ss'（JST）を Date に */
function parseJst_(s) {
  return new Date(s.replace(' ', 'T') + '+09:00');
}
