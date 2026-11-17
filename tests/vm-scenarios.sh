#!/usr/bin/env bash
# Simulate common delegate network problems on a disposable Ubuntu VM, run the preflight
# against each, and check that it reports the right diagnosis.
#
# Needs: Ubuntu with sudo, iptables, tinyproxy, mitmproxy, docker.io
#   sudo apt-get install -y tinyproxy mitmproxy docker.io && sudo systemctl disable --now tinyproxy
#
#   export ACCOUNT=<account ID> URL=<its Harness URL, e.g. https://app.harness.io>
#   tests/vm-scenarios.sh                 # every scenario
#   tests/vm-scenarios.sh drop443 proxy   # just these
#
# It changes the VM's firewall, clock and CA store, and puts them back after each scenario.
# Don't run it on a machine you care about.

HERE=$(cd "$(dirname "$0")/.." && pwd)
S="$HERE/harness-delegate-preflight.sh"
ACCOUNT=${ACCOUNT:?set ACCOUNT to a Harness account ID to test against}
URL=${URL:?set URL to the Harness URL of that account, e.g. https://app.harness.io}
OUT=${OUT:-/tmp/hdpf-vm}
mkdir -p "$OUT"
TP_PORT=8888; MITM_PORT=8080
PASSED=0; FAILED=0; FAILED_NAMES=""

say() { printf '\n\033[1;35m=== %s\033[0m\n' "$*"; }

reset_all() {
  sudo pkill -x tinyproxy 2>/dev/null; sudo pkill -f mitmdump 2>/dev/null
  for t in iptables ip6tables; do sudo "$t" -F OUTPUT; sudo "$t" -P OUTPUT ACCEPT; done
  if [ -f /usr/local/share/ca-certificates/hdpf-mitm.crt ]; then
    sudo rm -f /usr/local/share/ca-certificates/hdpf-mitm.crt; sudo update-ca-certificates --fresh >/dev/null 2>&1
  fi
  if [ -f "$OUT/clock-skewed" ]; then
    sudo timedatectl set-ntp true; rm -f "$OUT/clock-skewed"
    # Set the clock back from Google's Date header, in case NTP is slow to step it
    local d; d=$(curl -sI --max-time 5 https://www.google.com | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
    [ -n "$d" ] && sudo date -s "$d" >/dev/null
  fi
  if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
    sudo rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
    sudo systemctl daemon-reload; sudo systemctl restart docker
  fi
  sudo resolvectl flush-caches 2>/dev/null
  sleep 0.5
}

# block_direct_443 [DROP|REJECT]: block outbound 443 for everyone except tinyproxy and loopback
block_direct_443() {
  local how=${1:-DROP} extra=""
  [ "$how" = REJECT ] && extra="--reject-with tcp-reset"
  for t in iptables ip6tables; do
    sudo "$t" -A OUTPUT -o lo -j ACCEPT
    id tinyproxy >/dev/null 2>&1 && sudo "$t" -A OUTPUT -m owner --uid-owner tinyproxy -j ACCEPT
    # shellcheck disable=SC2086
    sudo "$t" -A OUTPUT -p tcp --dport 443 -j "$how" $extra
    # shellcheck disable=SC2086
    sudo "$t" -A OUTPUT -p tcp --dport 80 -j "$how" $extra
  done
}

# tinyproxy [extra config lines...]
start_tinyproxy() {
  {
    printf 'User tinyproxy\nGroup tinyproxy\nPort %s\nListen 127.0.0.1\nTimeout 60\n' "$TP_PORT"
    printf 'LogLevel Info\nMaxClients 50\nConnectPort 443\nConnectPort 80\nAllow 127.0.0.1\n'
    for l in "$@"; do printf '%s\n' "$l"; done
  } | sudo tee /etc/tinyproxy/hdpf.conf >/dev/null   # AppArmor lets tinyproxy read only /etc/tinyproxy
  sudo tinyproxy -c /etc/tinyproxy/hdpf.conf
  sleep 1
}

start_mitm() {   # start_mitm [addon.py]
  local addon=""; [ -n "${1:-}" ] && addon="-s $1"
  # shellcheck disable=SC2086
  sudo -b mitmdump --set confdir="$OUT/mitm" -p "$MITM_PORT" --listen-host 127.0.0.1 -q $addon >/dev/null 2>&1
  local i=0; while [ $i -lt 30 ] && ! (exec 3<>/dev/tcp/127.0.0.1/$MITM_PORT) 2>/dev/null; do sleep 0.5; i=$((i+1)); done
}

# run NAME EXPECT_RC "grep pattern" ... -- preflight args...
# Every pattern must appear in the output, and the exit status must match.
run() {
  local name=$1 want=$2; shift 2
  local pats=() a
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do pats+=("$1"); shift; done
  shift
  say "$name"
  "$@" > "$OUT/$name.txt" 2>&1
  local rc=$? ok=1 missing=""
  [ "$rc" = "$want" ] || { ok=0; missing="exit $rc (wanted $want)"; }
  for a in "${pats[@]}"; do grep -qE -- "$a" "$OUT/$name.txt" || { ok=0; missing="$missing | missing: $a"; }; done
  sed -n '/^── \(Harness manager\|Proxy\|DNS\|Delegate image\|Container runtime\|Summary\)/,/^$/p' "$OUT/$name.txt" | grep -E '✖|⚠|↳|✔|ℹ|\[(FAIL|WARN| OK |INFO)\]' | head -24
  if [ "$ok" = 1 ]; then printf '\033[32mSCENARIO PASSED\033[0m %s\n' "$name"; PASSED=$((PASSED+1))
  else printf '\033[31mSCENARIO FAILED\033[0m %s: %s\n' "$name" "$missing"; FAILED=$((FAILED+1)); FAILED_NAMES="$FAILED_NAMES $name"; fi
}

P() { "$S" --account-id "$ACCOUNT" --url "$URL" --no-report --timeout 5 "$@"; }

# ------------------------------------------------------------------------------------------
sc_baseline() {
  run baseline 0 'HTTPS to .* healthy' 'WebSocket +upgrade accepted' 'Layer download +works' -- P -t network
}

sc_drop443() {
  block_direct_443 DROP
  run drop443 1 'timed out connecting on port 443' 'no outbound internet access at all' -- P -t network
}

sc_reject443() {
  block_direct_443 REJECT
  run reject443 1 'connection refused on port 443' -- P -t network
}

sc_harness_blocked() {   # only Harness is blocked; the rest of the internet works
  local ip h
  for h in "${URL#https://}" accounts.harness.io app.harness.io; do
    for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j DROP; done
  done
  run harness_blocked 1 'Other HTTPS sites work' -- P -t network
}

sc_dns() {   # DNS servers unreachable
  for t in iptables ip6tables; do
    sudo "$t" -A OUTPUT -o lo -j ACCEPT
    sudo "$t" -A OUTPUT -p udp --dport 53 -j DROP; sudo "$t" -A OUTPUT -p tcp --dport 53 -j DROP
  done
  sudo resolvectl flush-caches
  run dns 1 "DNS isn't working|DNS lookup .* failed" -- P -t network
}

sc_proxy() {   # direct 443 blocked; only the proxy gets out
  start_tinyproxy; block_direct_443 DROP
  run proxy_missing 1 'timed out connecting on port 443' 'rerun with --proxy' -- P -t network
  run proxy_env 0 'HTTPS to .* via proxy +healthy' 'Without the proxy +blocked' 'PROXY_HOST=127.0.0.1 +PROXY_PORT=8888' \
    -- env HTTPS_PROXY="http://127.0.0.1:$TP_PORT" "$S" --account-id "$ACCOUNT" --url "$URL" --no-report --timeout 5 -t network
  run proxy_delegate_vars 0 'from PROXY_HOST' 'via proxy +healthy' \
    -- env PROXY_HOST=127.0.0.1 PROXY_PORT=$TP_PORT PROXY_SCHEME=http "$S" --account-id "$ACCOUNT" --url "$URL" --no-report --timeout 5 -t network
  run proxy_wrong_port 1 "can't connect to 127.0.0.1:9999" -- P -t network --proxy http://127.0.0.1:9999
}

sc_proxy_auth() {
  start_tinyproxy 'BasicAuth hdpf s3cret-Pa55'
  block_direct_443 DROP
  run proxy_auth_missing 1 'wants credentials \(HTTP 407\)' -- P -t network --proxy "http://127.0.0.1:$TP_PORT"
  run proxy_auth_ok 0 'via proxy +healthy' 'hdpf:\*\*\*\*@' 'PROXY_USER=hdpf' -- P -t network --proxy "http://hdpf:s3cret-Pa55@127.0.0.1:$TP_PORT"
  if grep -q 's3cret-Pa55' "$OUT/proxy_auth_ok.txt"; then echo "SCENARIO FAILED: the proxy password appears in the output"; FAILED=$((FAILED+1)); FAILED_NAMES="$FAILED_NAMES proxy_auth_leak"; fi
}

sc_proxy_deny() {   # the proxy's filter blocks harness.io
  printf 'harness\\.io$\n' | sudo tee /etc/tinyproxy/hdpf-deny >/dev/null
  start_tinyproxy 'Filter "/etc/tinyproxy/hdpf-deny"' 'FilterType ere' 'FilterDefaultDeny No'
  block_direct_443 DROP
  run proxy_deny 1 'proxy blocked .* \(HTTP 403' -- P -t network --proxy "http://127.0.0.1:$TP_PORT"
}

sc_cdn_blocked() {   # Docker Hub's API is allowed, its layer CDN isn't
  printf '%s\n' 'harness\.io$' 'googleapis\.com$' 'pkg\.dev$' 'docker\.io$' 'google\.com$' | sudo tee /etc/tinyproxy/hdpf-allow >/dev/null
  start_tinyproxy 'Filter "/etc/tinyproxy/hdpf-allow"' 'FilterType ere' 'FilterDefaultDeny Yes'
  block_direct_443 DROP
  run cdn_blocked 1 'Layer download .*cloudfront|layers come from .*cloudfront' \
    -- P -t network --proxy "http://127.0.0.1:$TP_PORT" --image harness/delegate:26.11.90410
}

sc_mitm() {   # TLS inspection
  start_mitm
  run mitm_untrusted 1 'certificate not trusted: issued by mitmproxy' 'delegateCustomCa' -- P -t network --proxy "http://127.0.0.1:$MITM_PORT"
  sudo cp "$OUT/mitm/mitmproxy-ca-cert.pem" /usr/local/share/ca-certificates/hdpf-mitm.crt
  sudo update-ca-certificates >/dev/null 2>&1
  run mitm_trusted 0 'TLS certificate +intercepted: issued by mitmproxy' 'ca-bundle' -- P -t network --proxy "http://127.0.0.1:$MITM_PORT"
  sudo pkill -f mitmdump; sleep 1
  cat > "$OUT/no-ws.py" <<'EOF'
from mitmproxy import http
def request(flow: http.HTTPFlow) -> None:
    if flow.request.headers.get("upgrade", "").lower() == "websocket":
        flow.response = http.Response.make(403, b"WebSockets are not allowed", {"Content-Type": "text/plain"})
EOF
  start_mitm "$OUT/no-ws.py"
  run mitm_no_websocket 0 'WebSocket +upgrade refused' 'POLL_FOR_TASKS=true' -- P -t network --proxy "http://127.0.0.1:$MITM_PORT"
}

sc_clock() {
  sudo timedatectl set-ntp false; touch "$OUT/clock-skewed"
  sudo date -s '+10 minutes' >/dev/null
  run clock_skew 1 "Clock .*s off Harness" 'timedatectl' -- P -t network
}

sc_docker() {
  if id -nG | grep -qw docker; then
    : # already in the group
  else
    run docker_perm 1 "can't talk to the Docker daemon" -- P -t docker
    sudo usermod -aG docker "$USER"
  fi
  # A proxy-only network where the daemon has no proxy. sg runs it with the new group.
  start_tinyproxy; block_direct_443 DROP
  run docker_no_daemon_proxy 1 'Docker daemon proxy +none set' 'http-proxy.conf' \
    -- sg docker -c "HTTPS_PROXY=http://127.0.0.1:$TP_PORT '$S' --account-id '$ACCOUNT' --url '$URL' --no-report --timeout 5 -t docker"
  sudo mkdir -p /etc/systemd/system/docker.service.d
  printf '[Service]\nEnvironment="HTTPS_PROXY=http://127.0.0.1:%s"\n' "$TP_PORT" | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
  sudo systemctl daemon-reload; sudo systemctl restart docker
  run docker_daemon_proxy 0 'Docker daemon proxy +http://127.0.0.1' \
    -- sg docker -c "HTTPS_PROXY=http://127.0.0.1:$TP_PORT '$S' --account-id '$ACCOUNT' --url '$URL' --no-report --timeout 5 -t docker"
}

sc_ascii() {
  run ascii 0 '\[ OK \] HTTPS to' -- env LANG=C LC_ALL=C "$S" --account-id "$ACCOUNT" --url "$URL" --no-report --timeout 5 -t network
}

ALL="baseline drop443 reject443 harness_blocked dns proxy proxy_auth proxy_deny cdn_blocked mitm clock docker ascii"
# Ubuntu's AppArmor profile lets tinyproxy read only its stock config; allow our test files too
if [ -f /etc/apparmor.d/tinyproxy ] && ! sudo grep -q hdpf /etc/apparmor.d/local/tinyproxy 2>/dev/null; then
  echo '  file r /etc/tinyproxy/hdpf*,   # hdpf tests' | sudo tee -a /etc/apparmor.d/local/tinyproxy >/dev/null
  sudo apparmor_parser -r /etc/apparmor.d/tinyproxy
fi
trap 'reset_all' EXIT INT TERM
reset_all
for s in ${*:-$ALL}; do
  "sc_$s"
  reset_all
done
printf '\n%s passed, %s failed%s\n' "$PASSED" "$FAILED" "${FAILED_NAMES:+:$FAILED_NAMES}"
[ "$FAILED" = 0 ]
