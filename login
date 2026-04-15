<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>RECORE Dashboard — ログイン</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f4f4f0; color: #111; font-size: 14px; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
.card { background: #fff; border: 1px solid #e8e8e4; border-radius: 10px; padding: 36px 40px; width: 100%; max-width: 420px; }
.logo { font-size: 13px; font-weight: 500; letter-spacing: 0.1em; color: #999; margin-bottom: 24px; }
h1 { font-size: 20px; font-weight: 500; margin-bottom: 6px; }
p { font-size: 13px; color: #888; margin-bottom: 28px; line-height: 1.7; }
label { font-size: 11px; color: #999; display: block; margin-bottom: 6px; letter-spacing: 0.04em; }
input[type=password] { width: 100%; padding: 10px 13px; border: 1px solid #ddd; border-radius: 7px; font-size: 13px; font-family: monospace; margin-bottom: 16px; outline: none; }
input[type=password]:focus { border-color: #111; }
button { width: 100%; padding: 10px; background: #111; color: #fff; border: none; border-radius: 7px; font-size: 13px; cursor: pointer; letter-spacing: 0.03em; }
button:hover { background: #333; }
#err { font-size: 12px; color: #f44336; margin-top: 12px; min-height: 18px; }
</style>
</head>
<body>
<div class="card">
  <div class="logo">RECORE DASHBOARD</div>
  <h1>APIキーを入力</h1>
  <p>READ専用APIキーを入力してください。キーはセッション中のみ保持されます。</p>
  <label>API KEY</label>
  <input type="password" id="apikey" placeholder="APIキーを貼り付け" />
  <button onclick="login()">接続して開始</button>
  <div id="err"></div>
</div>
<script>
async function login() {
  const key = document.getElementById('apikey').value.trim();
  if (!key) { document.getElementById('err').textContent = 'APIキーを入力してください'; return; }
  document.querySelector('button').textContent = '確認中...';
  document.getElementById('err').textContent = '';
  try {
    const r = await fetch('https://co-api.recore-pos.com/me', {
      headers: { 'Authorization': key }
    });
    if (!r.ok) throw new Error(r.status);
    sessionStorage.setItem('recore_key', key);
    location.href = 'index.html';
  } catch(e) {
    document.getElementById('err').textContent = '接続失敗しました。APIキーを確認してください。';
    document.querySelector('button').textContent = '接続して開始';
  }
}
document.getElementById('apikey').addEventListener('keydown', function(e){ if(e.key==='Enter') login(); });
if (sessionStorage.getItem('recore_key')) location.href = 'index.html';
</script>
</body>
</html>
