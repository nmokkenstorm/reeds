/// Static page served at `/dashboard`. It is a plain fold viewer: it polls
/// `GET /state`, groups by topic prefix, and renders ages. No websocket, no
/// build step, nothing baked in at compile time beyond this string, so the
/// page always reflects whatever `/state` returns right now.
pub fn page() -> String {
  "<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>reeds mesh state</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #0e1116;
    --fg: #d8dee9;
    --dim: #6b7280;
    --border: #262b33;
    --accent: #7dd3fc;
    --warn-bg: #2b1d0e;
    --warn-border: #a3651a;
    --warn-fg: #f5c98a;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f7f7f8;
      --fg: #1a1d23;
      --dim: #6b7280;
      --border: #dcdfe4;
      --accent: #0369a1;
      --warn-bg: #fff4e5;
      --warn-border: #e0a458;
      --warn-fg: #8a5a10;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 1.5rem;
    background: var(--bg);
    color: var(--fg);
    font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  header { margin-bottom: 1.25rem; }
  h1 { font-size: 1.05rem; margin: 0 0 0.35rem; }
  .honest {
    color: var(--dim);
    font-size: 0.85rem;
    max-width: 60ch;
  }
  #status {
    color: var(--dim);
    font-size: 0.8rem;
    margin-top: 0.5rem;
  }
  section.group, section.lane {
    margin-bottom: 1.25rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 0.6rem 0.8rem;
  }
  section.lane.needs-user {
    background: var(--warn-bg);
    border-color: var(--warn-border);
  }
  section.lane.needs-user h2 { color: var(--warn-fg); }
  h2 {
    font-size: 0.85rem;
    margin: 0 0 0.4rem;
    color: var(--accent);
    font-weight: 600;
  }
  ul { list-style: none; margin: 0; padding: 0; }
  li.entry {
    display: flex;
    gap: 0.6rem;
    align-items: baseline;
    padding: 0.2rem 0;
    border-top: 1px solid var(--border);
  }
  li.entry:first-child { border-top: none; }
  .topic { flex: 1 1 auto; overflow-wrap: anywhere; }
  .kind {
    color: var(--accent);
    flex: 0 0 auto;
  }
  .meta {
    color: var(--dim);
    flex: 0 0 auto;
    font-size: 0.85rem;
    white-space: nowrap;
  }
  .empty { color: var(--dim); }
</style>
</head>
<body>
<header>
  <h1>reeds mesh state</h1>
  <div class='honest'>
    Last whispered, not currently true. This is a fold over an append-only
    log: every row is the newest whisper seen on its topic, nothing more.
    Silence does not mean resolved, it means nobody has said anything since.
  </div>
  <div id='status'>loading&hellip;</div>
</header>
<div id='root'></div>
<script>
  var POLL_MS = 5000;

  function groupKey(topic) {
    var parts = topic.split('.');
    if (parts.length <= 1) return topic;
    return parts.slice(0, -1).join('.');
  }

  function fmtAge(ts) {
    var ms = Date.now() - ts;
    var s = Math.floor(ms / 1000);
    if (s < 5) return 'just now';
    if (s < 60) return s + 's ago';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h ago';
    var d = Math.floor(h / 24);
    return d + 'd ago';
  }

  function entryRow(e) {
    var li = document.createElement('li');
    li.className = 'entry';

    var topic = document.createElement('span');
    topic.className = 'topic';
    topic.textContent = e.topic;

    var kind = document.createElement('span');
    kind.className = 'kind';
    kind.textContent = e.kind;

    var metaText = e.sender + ' · ' + fmtAge(e.ts);
    if (e.origin) metaText += ' · ' + e.origin;
    var meta = document.createElement('span');
    meta.className = 'meta';
    meta.textContent = metaText;

    li.appendChild(topic);
    li.appendChild(kind);
    li.appendChild(meta);
    return li;
  }

  function section(title, entries, className) {
    var el = document.createElement('section');
    el.className = className;
    var h = document.createElement('h2');
    h.textContent = title;
    el.appendChild(h);
    var list = document.createElement('ul');
    entries.forEach(function (e) { list.appendChild(entryRow(e)); });
    el.appendChild(list);
    return el;
  }

  function render(entries) {
    var root = document.getElementById('root');
    root.innerHTML = '';

    if (entries.length === 0) {
      var empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'no whispers under this prefix';
      root.appendChild(empty);
      return;
    }

    var needsUser = entries.filter(function (e) { return e.kind === 'needs-user'; });
    if (needsUser.length > 0) {
      root.appendChild(section('needs you (' + needsUser.length + ')', needsUser, 'lane needs-user'));
    }

    var groups = {};
    var order = [];
    entries.forEach(function (e) {
      var key = groupKey(e.topic);
      if (!groups[key]) { groups[key] = []; order.push(key); }
      groups[key].push(e);
    });
    order.sort();
    order.forEach(function (key) {
      root.appendChild(section(key, groups[key], 'group'));
    });
  }

  function poll() {
    fetch('/state?prefix=*')
      .then(function (res) {
        if (!res.ok) throw new Error('status ' + res.status);
        return res.json();
      })
      .then(function (data) {
        render(data.entries);
        var stamp = new Date().toLocaleTimeString();
        document.getElementById('status').textContent =
          data.entries.length + ' live topics · refreshed ' + stamp;
      })
      .catch(function (err) {
        document.getElementById('status').textContent = 'poll failed: ' + err.message;
      });
  }

  poll();
  setInterval(poll, POLL_MS);
</script>
</body>
</html>
"
}
