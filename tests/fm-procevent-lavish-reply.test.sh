#!/usr/bin/env bash
# Reply-only adapter behavior with isolated synthetic sessions and HTTP server.
# FM_LAVISH_REPLY_LIVE=1 substitutes the installed lavish-axi server, never the
# shared daemon: fresh private state, explicit loopback/unused port, no browser,
# no CLI open/ensureServer, and only this test's child processes are stopped.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-lavish-reply)
SERVER_PID='' POLL_PID=''
cleanup() {
  [ -z "$POLL_PID" ] || { kill "$POLL_PID" 2>/dev/null || true; wait "$POLL_PID" 2>/dev/null || true; }
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  fm_test_cleanup
}
trap cleanup EXIT
export FM_HOME="$LAB/home" LAVISH_AXI_STATE_DIR="$LAB/store"
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
export LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_LINK_HOST=127.0.0.1
mkdir -p "$FM_HOME/state" "$LAVISH_AXI_STATE_DIR"
PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
export LAVISH_AXI_PORT=$PORT
BASE="http://127.0.0.1:$PORT"
ART="$LAB/review.html"
printf '<!doctype html><title>Synthetic reply fixture</title><input value="unsent synthetic control">\n' > "$ART"
printf 'Synthetic receipt\n\n- Preserve controls\n- Unicode: café 雪\n' > "$LAB/reply.md"
# The fake accepts only the observed installed 0.1.78 server API. It does not
# implement CLI polling or listener replacement. Live mode below proves the
# dependency assumptions independently against the installed implementation.
cat > "$LAB/server.cjs" <<'JS'
const http = require('http'), fs = require('fs'), path = require('path'), crypto = require('crypto');
const dir = process.env.LAVISH_AXI_STATE_DIR, lab = path.dirname(dir);
let listener = null;
const read = () => fs.existsSync(dir+'/state.json') ? JSON.parse(fs.readFileSync(dir+'/state.json')) : {sessions:{}};
const write = s => fs.writeFileSync(dir+'/state.json', JSON.stringify(s));
http.createServer(async (req,res) => {
  const u = new URL(req.url,'http://localhost');
  const mode = fs.existsSync(lab+'/mode') ? fs.readFileSync(lab+'/mode','utf8').trim() : '';
  const send = (s, code=200) => {res.writeHead(code,{'content-type':'application/json'});res.end(JSON.stringify(s))};
  if (u.pathname === '/health') return send({ok:true,app:'lavish-axi',version:mode==='old'?'0.1.77':mode==='newer'?'0.1.79':'0.1.78',state_dir:mode==='foreign'?lab:dir,listeners:listener?[{key:listener.key,label:'synthetic-receiver'}]:[]});
  if (req.method==='POST' && req.headers.origin && req.headers.origin!==`http://${req.headers.host}`) return send({error:'cross-origin request rejected'},403);
  if (u.pathname.endsWith('/prompts') && req.headers.origin!==`http://${req.headers.host}`) return send({error:'cross-origin prompt submission rejected'},403);
  let body=''; for await (const chunk of req) body+=chunk;
  const data = body ? JSON.parse(body) : {};
  const state = read();
  if (u.pathname === '/api/sessions') {
    const file=fs.realpathSync(data.file), key=crypto.createHash('sha256').update(file).digest('hex').slice(0,16);
    state.sessions[key]={key,file,url:`http://127.0.0.1:${process.env.LAVISH_AXI_PORT}/session/${key}`,status:'open',prompts:[],chat:[]};
    write(state); return send({key});
  }
  if (u.pathname === '/api/poll') {
    const session=Object.values(state.sessions).find(s=>s.file===u.searchParams.get('file'));
    if (listener) return send({code:'LISTENER_ACTIVE'},409);
    if (session.prompts.length) {const prompts=session.prompts;session.prompts=[];session.status='open';write(state);return send({status:'feedback',prompts})}
    listener={key:session.key,res};req.on('close',()=>{listener=null});return;
  }
  const match=u.pathname.match(/^\/api\/([0-9a-f]{16})\/(agent-reply|prompts)$/);
  if (!match || !state.sessions[match[1]]) return send({error:'missing'},404);
  const s=state.sessions[match[1]];
  if (match[2]==='agent-reply') {
    if (mode==='unsupported') return send({error:'unsupported'},404);
    s.chat.push({role:'agent',text:data.text});write(state);
    return send(mode==='uncertain'?{status:'unexpected'}:{status:'sent'});
  }
  s.prompts.push(...data.prompts);s.status='feedback';write(state);
  if (listener) {const pending=listener;listener=null;s.prompts=[];s.status='open';write(state);pending.res.end(JSON.stringify({status:'feedback',prompts:data.prompts}))}
  send({status:'queued'});
}).listen(Number(process.env.LAVISH_AXI_PORT),'127.0.0.1');
JS
if [ "${FM_LAVISH_REPLY_LIVE:-0}" = 1 ]; then
  command -v lavish-axi >/dev/null || fail 'live reply guard requires installed lavish-axi'
  lavish-axi --version
  lavish-axi server --port "$PORT" > "$LAB/server.log" 2>&1 &
else
  node "$LAB/server.cjs" > "$LAB/server.log" 2>&1 &
fi
SERVER_PID=$!
http() { curl --disable --noproxy '*' --silent --show-error --fail --max-time 10 "$@"; }
for ((i=0; i<100; i++)); do
  http "$BASE/health" > "$LAB/health.json" 2>/dev/null && break
  sleep 0.1
done
[ -s "$LAB/health.json" ] || fail 'isolated server did not start'
http --header 'Content-Type: application/json' --data "{\"file\":\"$ART\"}" "$BASE/api/sessions" > "$LAB/open.json"
KEY=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).key)' "$LAB/open.json")
printf '<!doctype html><title>Unrelated synthetic session</title>\n' > "$LAB/unrelated.html"
http --header 'Content-Type: application/json' --data "{\"file\":\"$LAB/unrelated.html\"}" "$BASE/api/sessions" > /dev/null
reply() { bash "$ROOT/bin/fm-procevent-lavish.sh" reply "$ART" --agent-reply-file "$LAB/reply.md"; }
reply_checked() {
  cp "$LAVISH_AXI_STATE_DIR/state.json" "$LAB/before-reply.json"
  reply
  node - "$LAB/before-reply.json" "$LAVISH_AXI_STATE_DIR/state.json" "$KEY" "$LAB/reply.md" <<'JS'
const fs=require('fs'),assert=require('assert');
const before=JSON.parse(fs.readFileSync(process.argv[2])), after=JSON.parse(fs.readFileSync(process.argv[3]));
const key=process.argv[4], b=before.sessions[key], a=after.sessions[key];
assert.strictEqual(a.chat.length,b.chat.length+1);
const entry=a.chat.pop();
assert.strictEqual(entry.role,'agent');
assert.strictEqual(entry.text,fs.readFileSync(process.argv[5],'utf8'));
for(const field of ['updated_at','chat_revision']) {delete a[field];delete b[field]}
assert.deepStrictEqual(after,before,'reply changed something beyond its own transcript/timestamp/revision');
JS
}
snapshot() { shasum "$LAVISH_AXI_STATE_DIR/state.json" "$ART" "$LAB/reply.md"; }
# Unlike agent-reply, prompts requires an Origin or Referer matching the request
# authority even for a non-browser client. The frontend's same-origin fetch
# supplies it automatically. Missing and cross-origin requests must still fail.
for origin in missing http://invalid.example; do
  headers=(--header 'Origin:')
  [ "$origin" = missing ] || headers=(--header "Origin: $origin")
  before=$(snapshot)
  code=$(curl --disable --noproxy '*' --silent --show-error --max-time 10 \
    "${headers[@]}" --header 'Content-Type: application/json' \
    --data '{"prompts":[{"tag":"message","prompt":"synthetic invalid request"}]}' \
    --output "$LAB/rejected.json" --write-out '%{http_code}' "$BASE/api/$KEY/prompts")
  [ "$code" = 403 ] || fail "invalid $origin prompt request returned $code"
  if [ "$origin" = missing ]; then
    assert_contains "$(< "$LAB/rejected.json")" 'cross-origin prompt submission rejected' 'missing Origin reaches the demonstrated route-specific rejection'
  else
    assert_contains "$(< "$LAB/rejected.json")" 'cross-origin request rejected' 'foreign Origin reaches the middleware rejection'
  fi
  [ "$before" = "$(snapshot)" ] || fail 'invalid prompt request changed state'
done
pass 'invalid feedback requests remain rejected without changing session state'
# Pending feedback is seeded via the actual feedback API with no active poll.
http --header "Origin: $BASE" --header 'Content-Type: application/json' --data '{"prompts":[{"tag":"message","prompt":"synthetic pending feedback"}]}' "$BASE/api/$KEY/prompts" > /dev/null
reply_checked > "$LAB/sent"
assert_contains "$(< "$LAB/sent")" "sent: $BASE/session/$KEY" 'reply uses the saved session, not ambient routing'
node - "$LAVISH_AXI_STATE_DIR/state.json" "$KEY" <<'JS'
const s=JSON.parse(require('fs').readFileSync(process.argv[2])).sessions[process.argv[3]];
if(s.prompts.length!==1 || s.chat.filter(x=>x.role==='agent').length!==1) process.exit(1);
JS
pass 'reply-only preserves pending feedback instead of consuming it'
http --get --data-urlencode "file=$ART" "$BASE/api/poll" > "$LAB/pending.json"
assert_contains "$(< "$LAB/pending.json")" 'synthetic pending feedback' 'independent receiver still obtains prior feedback'
# Keep one receiver alive and assert that both firstmate- and task-owned local
# records, its label and process, and unsent controls survive reply delivery.
for owner in firstmate task; do
  export FM_HOME="$LAB/home-$owner"
  mkdir -p "$FM_HOME/state"
  SOURCE=$(bash "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
  if [ "$owner" = task ]; then
    printf 'window=fmtest:fm-synthetic\nworktree=%s/isolated\nproject=synthetic\n' "$LAB" > "$FM_HOME/state/synthetic.meta"
    bash "$ROOT/bin/fm-procevent.sh" register-task lavish "$SOURCE" synthetic -- /usr/bin/true > /dev/null
  else
    bash "$ROOT/bin/fm-procevent.sh" register lavish "$SOURCE" -- /usr/bin/true > /dev/null
  fi
  RECORD="$FM_HOME/state/procevent/$SOURCE.source"
  before_record=$(shasum "$RECORD" "$ART" "$LAB/reply.md")
  http --get --data-urlencode "file=$ART" --data-urlencode 'owner=synthetic-receiver' "$BASE/api/poll" > "$LAB/received.json" &
  POLL_PID=$!
  for ((i=0; i<100; i++)); do
    http "$BASE/health" > "$LAB/before-health.json"
    grep -q synthetic-receiver "$LAB/before-health.json" && break
    sleep 0.1
  done
  grep -q synthetic-receiver "$LAB/before-health.json" || fail 'synthetic listener not ready'
  # Wrong ambient values must never redirect the reply away from the saved URL.
  LAVISH_AXI_HOST=unrelated.invalid LAVISH_AXI_PORT=1 reply_checked > /dev/null
  kill -0 "$POLL_PID" || fail 'reply replaced or finished the existing receiver'
  http "$BASE/health" > "$LAB/after-health.json"
  node - "$LAB/before-health.json" "$LAB/after-health.json" <<'JS'
const fs=require('fs'), a=JSON.parse(fs.readFileSync(process.argv[2])), b=JSON.parse(fs.readFileSync(process.argv[3]));
if(JSON.stringify(a.listeners)!==JSON.stringify(b.listeners) || b.listeners.length!==1)process.exit(1);
JS
  [ "$before_record" = "$(shasum "$RECORD" "$ART" "$LAB/reply.md")" ] || fail 'reply changed receiver record, artifact, or input reply file'
  http --header "Origin: $BASE" --header 'Content-Type: application/json' --data '{"prompts":[{"tag":"message","prompt":"synthetic independent feedback"}]}' "$BASE/api/$KEY/prompts" > /dev/null
  wait "$POLL_PID"; POLL_PID=''
  assert_contains "$(< "$LAB/received.json")" 'synthetic independent feedback' "$owner receiver independently receives subsequent feedback"
  pass "$owner receiver identity survives same-session reply with no duplicate listener"
done
# Invalid identity must refuse before any write, regardless of server flavor.
cp "$LAVISH_AXI_STATE_DIR/state.json" "$LAB/saved.json"
node - "$LAVISH_AXI_STATE_DIR/state.json" "$KEY" <<'JS'
const fs=require('fs'),p=process.argv[2],s=JSON.parse(fs.readFileSync(p));s.sessions[process.argv[3]].url=s.sessions[process.argv[3]].url.replace(process.argv[3],'0000000000000000');fs.writeFileSync(p,JSON.stringify(s));
JS
before=$(snapshot)
if reply > "$LAB/error" 2>&1; then fail 'mismatched session identity accepted'; fi
[ "$before" = "$(snapshot)" ] || fail 'invalid identity changed fixture state'
cp "$LAB/saved.json" "$LAVISH_AXI_STATE_DIR/state.json"
pass 'mismatched saved session identity refuses without side effects'
node - "$LAVISH_AXI_STATE_DIR/state.json" "$KEY" <<'JS'
const fs=require('fs'),p=process.argv[2],s=JSON.parse(fs.readFileSync(p));s.sessions[process.argv[3]].status='ended';fs.writeFileSync(p,JSON.stringify(s));
JS
before=$(snapshot)
if reply > "$LAB/error" 2>&1; then fail 'ended session accepted a reply'; fi
[ "$before" = "$(snapshot)" ] || fail 'ended session was changed or reopened'
cp "$LAB/saved.json" "$LAVISH_AXI_STATE_DIR/state.json"
cp "$LAB/reply.md" "$LAB/saved-reply.md"
printf '  \n' > "$LAB/reply.md"
before=$(snapshot)
if reply > "$LAB/error" 2>&1; then fail 'blank reply accepted'; fi
[ "$before" = "$(snapshot)" ] || fail 'blank reply changed state or was consumed'
cp "$LAB/saved-reply.md" "$LAB/reply.md"
pass 'ended session and invalid reply refuse without reopening or consumption'
if [ "${FM_LAVISH_REPLY_LIVE:-0}" != 1 ]; then
  for mode in old newer foreign unsupported; do
    printf '%s\n' "$mode" > "$LAB/mode"
    before=$(snapshot)
    if reply > "$LAB/error" 2>&1; then fail "$mode support claimed success"; fi
    [ "$before" = "$(snapshot)" ] || fail "$mode server changed state"
  done
  printf 'uncertain\n' > "$LAB/mode"
  if reply > "$LAB/error" 2>&1; then fail 'unexpected response claimed acceptance'; fi
  assert_contains "$(< "$LAB/error")" 'inspect conversation before any manual retry' 'ambiguous delivery never automatically retries'
  node - "$LAVISH_AXI_STATE_DIR/state.json" "$KEY" <<'JS'
const s=JSON.parse(require('fs').readFileSync(process.argv[2])).sessions[process.argv[3]];
if(s.chat.filter(x=>x.role==='agent').length!==4)process.exit(1);
JS
  pass 'unavailable support refuses honestly; uncertain acceptance posts at most once'
fi
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=''
before=$(snapshot)
if reply > "$LAB/error" 2>&1; then fail 'stopped server claimed delivery'; fi
[ "$before" = "$(snapshot)" ] || fail 'unavailable server changed private state'
pass 'unavailable server refuses without starting or replacing a service'
pass 'reply tests used only private synthetic sessions; no browser or shared service touched'
