/**
 * BigQuery 書き込み・クエリ
 * 書き込みは load job（無料）を使う。streaming insert は使わない
 */

function bqLoadRows_(tableId, rows, opts) {
  if (!rows.length) return;
  const cfg = getConfig_();
  opts = opts || {};
  const load = {
    destinationTable: { projectId: cfg.projectId, datasetId: cfg.dataset, tableId: tableId },
    sourceFormat: 'NEWLINE_DELIMITED_JSON',
    writeDisposition: opts.truncate ? 'WRITE_TRUNCATE' : 'WRITE_APPEND',
  };
  if (opts.schema) load.schema = { fields: opts.schema };

  const ndjson = rows.map((r) => JSON.stringify(r)).join('\n');
  const blob = Utilities.newBlob(ndjson, 'application/octet-stream');
  const job = BigQuery.Jobs.insert(
    { jobReference: { projectId: cfg.projectId, location: cfg.location }, configuration: { load: load } },
    cfg.projectId,
    blob
  );
  bqWaitJob_(job.jobReference);
}

function bqQuery_(sql) {
  const cfg = getConfig_();
  let res = BigQuery.Jobs.query(
    { query: sql, useLegacySql: false, location: cfg.location, timeoutMs: 60000 },
    cfg.projectId
  );
  const jobId = res.jobReference.jobId;
  while (!res.jobComplete) {
    Utilities.sleep(1000);
    res = BigQuery.Jobs.getQueryResults(cfg.projectId, jobId, { location: cfg.location });
  }
  let rows = res.rows || [];
  let pageToken = res.pageToken;
  while (pageToken) {
    const page = BigQuery.Jobs.getQueryResults(cfg.projectId, jobId, { location: cfg.location, pageToken: pageToken });
    rows = rows.concat(page.rows || []);
    pageToken = page.pageToken;
  }
  return rows.map((r) => r.f.map((c) => c.v));
}

function bqWaitJob_(ref) {
  const cfg = getConfig_();
  for (;;) {
    const job = BigQuery.Jobs.get(cfg.projectId, ref.jobId, { location: ref.location || cfg.location });
    if (job.status.state === 'DONE') {
      if (job.status.errorResult) {
        throw new Error('BigQuery job失敗: ' + JSON.stringify(job.status.errors || job.status.errorResult).slice(0, 1000));
      }
      return job;
    }
    Utilities.sleep(1000);
  }
}
