#!/usr/bin/env bash

set -euo pipefail

html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
url_decode() {
local data=${1//+/ } && printf '%b' "${data//%/\\x}"
}


# Read request body if present (CGI passes it on stdin)
BODY=""
if [[ "${REQUEST_METHOD:-}" == "POST" ]] && [[ -n "${CONTENT_LENGTH:-}" ]]; then
# shellcheck disable=SC2162
IFS= read -r -N "${CONTENT_LENGTH}" BODY || true
fi


# Parse query params into lines key=value (decoded)
parse_kv() {
local q="$1"
IFS='&' read -r -a items <<< "$q"
for it in "${items[@]:-}"; do
[[ -z "$it" ]] && continue
key=${it%%=*}
val=${it#*=}
printf '%s=%s\n' "$(url_decode "$key")" "$(url_decode "${val:-}")"
done
}


# Response
printf 'Content-Type: text/html\r\n\r\n'
cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Bash CGI Echo</title>
<style>
body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, "Helvetica Neue", Arial, "Noto Sans", "Apple Color Emoji", "Segoe UI Emoji"; margin: 2rem; }
h1 { margin: 0 0 0.5rem 0; }
.grid { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 1rem; }
.muted { color: #666; font-size: 0.9em; }
table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
th, td { border: 1px solid #ddd; padding: 0.4rem 0.6rem; text-align: left; }
th { background: #f3f4f6; }
pre { background: #0b1020; color: #d1d5db; padding: 0.75rem; overflow-x: auto; border-radius: 6px; }
form { margin: 1rem 0; }
input, button, textarea { font: inherit; }
.row { margin: 0.5rem 0; }
</style>
</head>
<body>
<h1>Bash CGI Echo</h1>
<div class="muted">This page shows CGI environment, headers, query params and request body.</div>


<h2>Quick test</h2>
<form method="get">
<div class="row"><input name="foo" placeholder="foo" value="bar"/></div>
<div class="row"><input name="hello" placeholder="hello" value="world"/></div>
<button type="submit">GET submit</button>
</form>
<form method="post">
<div class="row"><input name="alpha" placeholder="alpha" value="beta"/></div>
<div class="row"><textarea name="note" rows="3" cols="40">Some text…</textarea></div>
<button type="submit">POST submit</button>
</form>


<h2>Request summary</h2>
<div class="grid">
<div>Method</div><div><code>"HTML
HTML
printf '%s' "${REQUEST_METHOD:-}" | html_escape
cat <<'HTML'
</code></div>
<div>URI</div><div><code>"HTML
HTML
printf '%s' "${REQUEST_URI:-}" | html_escape
cat <<'HTML'
</code></div>
<div>Query string</div><div><code>"HTML
HTML
printf '%s' "${QUERY_STRING:-}" | html_escape
cat <<'HTML'
</code></div>
<div>Content-Type</div><div><code>"HTML
HTML
printf '%s' "${CONTENT_TYPE:-}" | html_escape
cat <<'HTML'
</code></div>
<div>Content-Length</div><div><code>"HTML
HTML
printf '%s' "${CONTENT_LENGTH:-}" | html_escape
cat <<'HTML'
</code></div>
<div>Remote addr</div><div><code>"HTML
HTML
printf '%s' "${REMOTE_ADDR:-}" | html_escape
cat <<'HTML'
</code></div>
</div>


<h2>Query parameters</h2>
<table>
<thead><tr><th>Key</th><th>Value</th></tr></thead>
<tbody>
HTML


if [[ -n "${QUERY_STRING:-}" ]]; then
while IFS='=' read -r k v; do
printf '<tr><td><code>%s</code></td><td><code>%s</code></td></tr>\n' \
"$(printf '%s' "$k" | html_escape)" \
"$(printf '%s' "${v:-}" | html_escape)"
done < <(parse_kv "${QUERY_STRING}")
else
echo '<tr><td colspan="2"><em>(none)</em></td></tr>'
fi


cat <<'HTML'
</tbody>
</table>


<h2>Headers</h2>
<table>
<thead><tr><th>Header</th><th>Value</th></tr></thead>
<tbody>
HTML


HTML