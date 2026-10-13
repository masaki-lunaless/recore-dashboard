/**
 * RECORE co-api クライアント
 * https://novasto.github.io/ReCORE.co-api/spec/
 */

function recoreGet_(path, params) {
  const cfg = getConfig_();
  const query = Object.keys(params || {})
    .filter((k) => params[k] !== undefined && params[k] !== null)
    .map((k) => encodeURIComponent(k) + '=' + encodeURIComponent(params[k]))
    .join('&');
  const url = RECORE_BASE_URL + path + (query ? '?' + query : '');

  for (let attempt = 0; attempt < 5; attempt++) {
    Utilities.sleep(REQUEST_INTERVAL_MS);
    const res = UrlFetchApp.fetch(url, {
      method: 'get',
      headers: { Authorization: cfg.apiKey, 'Content-Type': 'application/json' },
      muteHttpExceptions: true,
    });
    const code = res.getResponseCode();
    if (code === 200) {
      return { body: JSON.parse(res.getContentText()), headers: lowerKeys_(res.getAllHeaders()) };
    }
    if (code === 429 || code >= 500) {
      Utilities.sleep(1000 * Math.pow(2, attempt));
      continue;
    }
    throw new Error('RECORE ' + code + ' ' + path + ': ' + res.getContentText().slice(0, 500));
  }
  throw new Error('RECORE リトライ上限: ' + path);
}

function lowerKeys_(obj) {
  const out = {};
  Object.keys(obj).forEach((k) => { out[k.toLowerCase()] = obj[k]; });
  return out;
}

/** RECOREのクエリ用日時文字列（JST） */
function recoreDateTime_(date) {
  return Utilities.formatDate(date, 'Asia/Tokyo', 'yyyy-MM-dd HH:mm:ss');
}

/** 個人情報などを落としたケースJSONを返す */
function sanitizeCase_(c) {
  const out = Object.assign({}, c);
  if (c.birthdate) out.birth_year = Number(String(c.birthdate).slice(0, 4)) || null;
  CASE_DROP_KEYS.forEach((k) => { delete out[k]; });
  out.goods = (c.goods || []).map((g) => {
    const gg = Object.assign({}, g);
    GOODS_DROP_KEYS.forEach((k) => { delete gg[k]; });
    return gg;
  });
  return out;
}
