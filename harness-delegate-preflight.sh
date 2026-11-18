#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Not an official Harness tool: provided as is, and not supported by Harness.
# harness-delegate-preflight.sh: check that a machine or Kubernetes cluster can run a
# Harness Delegate, and explain what to fix when it can't.
#
# Runs on macOS (bash 3.2 and later) and Linux. Needs only curl. Uses kubectl, helm and
# docker when they're there. It changes nothing, except that with --target k8s it starts
# one short-lived pod to test the cluster's own network path (skip that with --no-in-cluster).
#
#   ./harness-delegate-preflight.sh --account-id <ID>          # finds your Harness cluster
#   ./harness-delegate-preflight.sh --url '<your browser URL>'  # the account ID is read from it
#   ./harness-delegate-preflight.sh --target k8s -n harness-delegate-ng
#   ./harness-delegate-preflight.sh --target docker --proxy http://proxy.example.com:3128
#
# Run with --help for every option. HDPF_SCRIPT_MARKER (the in-cluster check looks for this)

VERSION="1.0.1"
DEFAULT_GAR_REPO="us-docker.pkg.dev/gar-prod-setup/harness-public/harness/delegate"
DEFAULT_DH_REPO="harness/delegate"
FALLBACK_TAG="26.11.90410"
HELM_REPO_URL="https://app.harness.io/storage/harness-download/delegate-helm-chart"
# SaaS clusters, in the order they're tried when only an account ID is known.
SAAS_MANAGERS="https://app.harness.io https://app.harness.io/gratis https://app3.harness.io https://accounts.harness.io https://accounts.eu.harness.io"

# ---------------------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------------------
URL=""; ACCOUNT_ID=""; TARGET="auto"; NAMESPACE="harness-delegate-ng"; KCONTEXT=""
IN_CLUSTER="auto"; IMAGE=""; IMAGE_PULL_SECRET=""; POD_LABELS=""; POD_TIMEOUT=300
PROXY_OPT=""; NOPROXY_OPT=""; DIRECT_ONLY=0; EXTRA_CHECKS=""; REPORT=""; NO_REPORT=0
T=8; COLOR="auto"; SYMBOLS="auto"; INTERACTIVE="auto"; IN_POD=0; DO_PULL=0; VERBOSE=0
HELM_VALUES=(); HELM_SETS=(); HELM_CHART=""; HELM_CHART_VERSION=""; HELM_MODE=0

usage() {
  cat <<'EOF'
Harness Delegate preflight: checks DNS, firewall, proxy, TLS inspection, clock, image
registry access and the host or cluster, then says what to fix.

Usage: harness-delegate-preflight.sh [options]

Where's your Harness account? (give either; with neither, it asks)
  -a, --account-id ID     Your account ID. Finds the right Harness cluster for you
  -u, --url URL           Your Harness URL: the browser address bar works, or the
                          MANAGER_HOST_AND_PORT value from the delegate install command

Where will the delegate run?
  -t, --target TYPE       k8s, docker (a VM or host with Docker), or network (checks only
                          the network). Default: asks, or picks from what's installed
  -n, --namespace NS      Kubernetes namespace for the delegate [harness-delegate-ng]
      --context CTX       kubectl context [the current one]
      --no-in-cluster     Don't start the probe pod that tests the cluster's own network
      --image IMAGE       Delegate image to test [latest from Harness's registry]. Use this
                          if you mirror the image to your own registry
      --image-pull-secret NAME   Pull secret for --image, for the probe pod
      --pod-label K=V     Extra label on the probe pod (repeat), e.g. to match a
                          NetworkPolicy that allows the delegate's egress
      --pod-timeout SECS  How long to wait for the probe pod to start [300]
      --pull              With --target docker, really docker pull the image (about 1 GB)

Installing with Helm? Give the same values you'll install with, and the probe pod runs as
the delegate pod will: same image, proxy, CA, labels, node selector, tolerations, pull
secret and service account. Implies --target k8s
  -f, --values FILE       A Helm values file (repeat). Account, URL and image come from it
      --set KEY=VALUE     A Helm --set value (repeat)
      --chart REF         The delegate chart, if you mirror it [harness-delegate-ng from
                          Harness's chart repo]: a path, an oci:// URL, or repo/chart
      --chart-version V   Chart version [latest]

Network
      --proxy URL         Proxy to test: http://host:port or http://user:pass@host:port.
                          Default: PROXY_HOST/PROXY_PORT, then HTTPS_PROXY from your shell
      --no-proxy LIST     Hosts that bypass the proxy [NO_PROXY from your shell]
      --direct            Ignore proxy settings in the environment
      --check HOST[:PORT] Also test a host the delegate will need, such as your Git
                          server or artifact repo (repeat). Port 443 if not given
      --timeout SECS      Timeout for each network check [8]

Output
      --report FILE       Where to save the report [./harness-delegate-preflight-<time>.txt]
      --no-report         Don't save a report
      --no-color          Plain output
      --yes               Don't ask questions; use defaults
  -v, --verbose           Show raw curl errors
  -h, --help              This help
      --version           Print the version

Exit status: 0 if nothing failed (warnings are OK), 1 if a check failed, 2 for bad usage.
EOF
}

usage_err() { printf 'harness-delegate-preflight: %s (try --help)\n' "$1" >&2; exit 2; }

getval() {   # called with the remaining "$@"; reads arg, val, has_val from the loop
  if [ "$has_val" = 1 ]; then OPTVAL=$val; SHIFT=1
  elif [ $# -ge 2 ]; then OPTVAL=$2; SHIFT=2
  else usage_err "$arg needs a value"; fi
}
while [ $# -gt 0 ]; do
  arg=$1; val=""; has_val=0; SHIFT=1
  case $arg in --*=*) val=${arg#*=}; arg=${arg%%=*}; has_val=1 ;; esac
  case $arg in
    -a|--account-id) getval "$@"; ACCOUNT_ID=$OPTVAL ;;
    -u|--url) getval "$@"; URL=$OPTVAL ;;
    -t|--target) getval "$@"; TARGET=$OPTVAL ;;
    -n|--namespace) getval "$@"; NAMESPACE=$OPTVAL ;;
    --context) getval "$@"; KCONTEXT=$OPTVAL ;;
    --no-in-cluster) IN_CLUSTER=0 ;;
    --in-cluster) IN_CLUSTER=1 ;;
    --image) getval "$@"; IMAGE=$OPTVAL ;;
    --image-pull-secret) getval "$@"; IMAGE_PULL_SECRET=$OPTVAL ;;
    --pod-label) getval "$@"; POD_LABELS="$POD_LABELS $OPTVAL" ;;
    --pod-timeout) getval "$@"; POD_TIMEOUT=$OPTVAL ;;
    --pull) DO_PULL=1 ;;
    -f|--values) getval "$@"; HELM_VALUES+=("$OPTVAL") ;;
    --set) getval "$@"; HELM_SETS+=("$OPTVAL") ;;
    --chart) getval "$@"; HELM_CHART=$OPTVAL ;;
    --chart-version) getval "$@"; HELM_CHART_VERSION=$OPTVAL ;;
    --proxy) getval "$@"; PROXY_OPT=$OPTVAL ;;
    --no-proxy) getval "$@"; NOPROXY_OPT=$OPTVAL ;;
    --direct) DIRECT_ONLY=1 ;;
    --check) getval "$@"; EXTRA_CHECKS="$EXTRA_CHECKS $OPTVAL" ;;
    --timeout) getval "$@"; T=$OPTVAL ;;
    --report) getval "$@"; REPORT=$OPTVAL ;;
    --no-report) NO_REPORT=1 ;;
    --no-color) COLOR="never" ;;
    --color) getval "$@"; COLOR=$OPTVAL ;;
    --symbols) getval "$@"; SYMBOLS=$OPTVAL ;;
    --yes|-y|--non-interactive) INTERACTIVE=0 ;;
    --in-pod) IN_POD=1; INTERACTIVE=0; NO_REPORT=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "harness-delegate-preflight $VERSION"; exit 0 ;;
    *) usage_err "unknown option: $1" ;;
  esac
  shift "$SHIFT"
done

IMAGE_CLI=0; [ -n "$IMAGE" ] && IMAGE_CLI=1
PROBE_ID=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 5); PROBE_ID=${PROBE_ID:-probe}
HELM_REL="hdpf-$PROBE_ID"; HELM_DIR=""; HELM_RES_NS=""; HV_FIX=""; HV_ACCT=""; HV_MGR=""; HV_POLL=""; HV_CA=""; HV_PROXY=""; HV_NAME=""
case $TARGET in auto|k8s|docker|network) ;; kubernetes) TARGET=k8s ;; vm|host) TARGET=docker ;;
  *) usage_err "--target must be k8s, docker or network" ;; esac
case $T in ''|*[!0-9]*) usage_err "--timeout must be a number of seconds" ;; esac
case $POD_TIMEOUT in ''|*[!0-9]*) usage_err "--pod-timeout must be a number of seconds" ;; esac
if [ "${#HELM_VALUES[@]}" -gt 0 ] || [ "${#HELM_SETS[@]}" -gt 0 ] || [ -n "$HELM_CHART" ]; then
  HELM_MODE=1
  case $TARGET in auto) TARGET=k8s ;; k8s) ;; *) usage_err "--values, --set and --chart are for --target k8s" ;; esac
  for f in "${HELM_VALUES[@]}"; do [ -r "$f" ] || usage_err "can't read the values file $f"; done
fi

# ---------------------------------------------------------------------------------------
# Terminal UI
# ---------------------------------------------------------------------------------------
IS_TTY=0; [ -t 1 ] && IS_TTY=1
if [ "$COLOR" = auto ]; then
  if [ "$IS_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then COLOR=always; else COLOR=never; fi
fi
if [ "$SYMBOLS" = auto ]; then
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) SYMBOLS=utf8 ;; *) SYMBOLS=ascii ;; esac
fi
if [ "$COLOR" = always ]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_R=""; C_B=""; C_D=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYN=""; C_MAG=""
fi
if [ "$SYMBOLS" = utf8 ]; then
  S_PASS="✔"; S_FAIL="✖"; S_WARN="⚠"; S_INFO="ℹ"; S_SKIP="○"; S_HINT="↳"; S_RULE="─"
  SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  S_PASS="[ OK ]"; S_FAIL="[FAIL]"; S_WARN="[WARN]"; S_INFO="[INFO]"; S_SKIP="[SKIP]"; S_HINT="->"; S_RULE="-"
  SPIN_FRAMES=('|' '/' '-' '\')
fi
ESC=$(printf '\033')
LABEL_W=30
N_PASS=0; N_WARN=0; N_FAIL=0
REC_KIND=(); REC_LABEL=(); REC_MSG=(); REC_HINT=()
SPIN_PID=""; SECTION=""; POD=""; KUBECTL=(kubectl)

strip_ansi() { sed "s/${ESC}\[[0-9;]*[A-Za-z]//g"; }

# out LINE: to the terminal, and without colour to the report
out() {
  printf '%s\n' "$1"
  if [ -n "${REPORT_OPEN:-}" ]; then printf '%s\n' "$1" | strip_ansi >&3; fi
}
rep() { [ -n "${REPORT_OPEN:-}" ] && printf '%s\n' "$1" >&3; return 0; }   # report only

rule() { local n=$1 s=""; while [ "$n" -gt 0 ]; do s="$s$S_RULE"; n=$((n-1)); done; printf '%s' "$s"; }

section() {
  spin_stop
  LAST_HINT=""
  SECTION=$1
  local t=" $1 "
  [ "$IN_POD" = 1 ] && t=" Pod: $1 "
  local n=$((64 - ${#t})); [ "$n" -lt 3 ] && n=3
  out ""
  out "${C_B}${C_CYN}$(rule 2)${t}$(rule "$n")${C_R}"
}

spin_start() {
  CUR_LABEL=$1
  [ "$IS_TTY" = 1 ] || return 0
  spin_stop
  (
    trap 'exit 0' TERM INT
    i=0; n=${#SPIN_FRAMES[@]}
    while :; do
      printf '\r  %s%s%s %s%s' "$C_CYN" "${SPIN_FRAMES[$((i % n))]}" "$C_R" "$1" "$(printf '\033[K')"
      i=$((i + 1)); sleep 0.1
    done
  ) &
  SPIN_PID=$!
}
spin_stop() {
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=""
    printf '\r\033[K'
  fi
}

# Records for the summary. Hints can have several lines; \037 stands for a newline in transit.
record() {
  REC_KIND[${#REC_KIND[@]}]=$1; REC_LABEL[${#REC_LABEL[@]}]=$2
  REC_MSG[${#REC_MSG[@]}]=$3; REC_HINT[${#REC_HINT[@]}]=$4
  if [ "$IN_POD" = 1 ]; then
    printf '##HDPF|%s|%s|%s|%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n' '\037')"
  fi
}

_result() {
  spin_stop
  local kind=$1 label=$2 detail=${3-} sym col pad
  case $kind in
    pass) sym=$S_PASS; col=$C_GRN; N_PASS=$((N_PASS + 1)) ;;
    warn) sym=$S_WARN; col=$C_YEL; N_WARN=$((N_WARN + 1)) ;;
    fail) sym=$S_FAIL; col=$C_RED; N_FAIL=$((N_FAIL + 1)) ;;
    info) sym=$S_INFO; col=$C_BLU ;;
    skip) sym=$S_SKIP; col=$C_D ;;
  esac
  pad=$(printf "%-${LABEL_W}s" "$label")
  if [ "$kind" = fail ]; then
    out "  ${col}${sym}${C_R} ${C_B}${pad}${C_R} ${detail}"
  else
    out "  ${col}${sym}${C_R} ${pad} ${C_D}${detail}${C_R}"
  fi
  [ "$IN_POD" = 1 ] && [ "$kind" = pass ] && printf '##HDPF|pass|%s||\n' "$label"
  return 0
}
LAST_HINT=""
hint() {
  local first=1 line
  if [ "$1" = "$LAST_HINT" ]; then out "      ${C_YEL}${S_HINT}${C_R} ${C_D}same fix as above${C_R}"; return; fi
  LAST_HINT=$1
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then out "      ${C_YEL}${S_HINT}${C_R} ${line}"; first=0
    else out "        ${line}"; fi
  done <<EOF
$1
EOF
}
pass() { _result pass "$1" "${2-}"; }
info() { _result info "$1" "${2-}"; }
skip() { _result skip "$1" "${2-}"; }
warn() { _result warn "$1" "${2-}"; [ -n "${3-}" ] && hint "$3"; record warn "$1" "${2-}" "${3-}"; }
fail() { _result fail "$1" "${2-}"; [ -n "${3-}" ] && hint "$3"; record fail "$1" "${2-}" "${3-}"; }
verbose() { [ "$VERBOSE" = 1 ] && out "      ${C_D}$1${C_R}"; rep "      [raw] $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------------
# Workspace and cleanup
# ---------------------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hdpf.XXXXXX") || { echo "can't create a temp directory" >&2; exit 1; }
chmod 700 "$WORK"
cleanup() {
  spin_stop
  if [ -n "$POD" ]; then
    "${KUBECTL[@]}" delete pod "$POD" -n "$NAMESPACE" --grace-period=0 --wait=false >/dev/null 2>&1
    POD=""
  fi
  if [ -n "$HELM_RES_NS" ] && [ -s "$HELM_DIR/res.yaml" ]; then
    "${KUBECTL[@]}" delete -n "$HELM_RES_NS" -f "$HELM_DIR/res.yaml" --ignore-not-found --wait=false >/dev/null 2>&1
    HELM_RES_NS=""
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'cleanup; printf "\nInterrupted.\n"; exit 130' INT TERM

# with_timeout SECS CMD...: run an external command with a time limit (macOS has no timeout(1))
with_timeout() {
  local secs=$1; shift
  if have timeout; then timeout "$secs" "$@"; return $?; fi
  if have gtimeout; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local w=$!
  wait "$pid"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# ---------------------------------------------------------------------------------------
# Helpers: URLs, proxies, DNS, TCP, HTTP
# ---------------------------------------------------------------------------------------
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# parse_manager_url URL: sets MGR_BASE, MGR_HOST, MGR_PORT, MGR_SCHEME; may set ACCOUNT_ID
parse_manager_url() {
  local u=$1 rest hostport path acct
  case $u in *://*) ;; *) u="https://$u" ;; esac
  MGR_SCHEME=$(lower "${u%%://*}")
  rest=${u#*://}
  hostport=${rest%%[/#?]*}
  path=${rest#"$hostport"}
  # A browser URL carries the account ID: .../account/<ID>/...
  acct=$(printf '%s' "$path" | sed -n 's#.*/account/\([A-Za-z0-9_-]\{6,\}\).*#\1#p' | head -1)
  if [ -n "$acct" ] && [ -z "$ACCOUNT_ID" ]; then ACCOUNT_ID=$acct; URL_GAVE_ACCOUNT=1; fi
  # Keep only a cluster prefix (prod-2 uses /gratis); drop /ng/..., /gateway, #/... and the rest
  case $path in /gratis|/gratis/*|/gratis#*|/gratis\?*) path=/gratis ;; *) path="" ;; esac
  MGR_HOST=$(lower "${hostport%%:*}")
  case $hostport in *:*) MGR_PORT=${hostport##*:} ;; *) if [ "$MGR_SCHEME" = http ]; then MGR_PORT=80; else MGR_PORT=443; fi ;; esac
  MGR_BASE="$MGR_SCHEME://$hostport$path"
}

# parse_proxy URL: sets PX_URL PX_SCHEME PX_HOST PX_PORT PX_USER PX_DISPLAY
parse_proxy() {
  local u=$1 rest cred hostport
  case $u in *://*) ;; *) u="http://$u" ;; esac
  PX_SCHEME=$(lower "${u%%://*}")
  rest=${u#*://}; rest=${rest%%/*}
  PX_USER=""; cred=""
  case $rest in *@*) cred=${rest%@*}; hostport=${rest##*@}; PX_USER=${cred%%:*} ;; *) hostport=$rest ;; esac
  PX_HOST=${hostport%%:*}
  case $hostport in *:*) PX_PORT=${hostport##*:} ;; *) PX_PORT="" ;; esac
  PX_URL="$PX_SCHEME://${cred:+$cred@}$PX_HOST${PX_PORT:+:$PX_PORT}"
  if [ -n "$cred" ]; then
    case $cred in *:*) PX_DISPLAY="$PX_SCHEME://$PX_USER:****@$PX_HOST${PX_PORT:+:$PX_PORT}" ;;
                  *) PX_DISPLAY="$PX_SCHEME://$PX_USER@$PX_HOST${PX_PORT:+:$PX_PORT}" ;; esac
  else PX_DISPLAY=$PX_URL; fi
}

# in_no_proxy HOST: true if HOST matches an entry in NOPROXY_LIST
in_no_proxy() {
  local h e
  h=$(lower "$1")
  for e in $(printf '%s' "$NOPROXY_LIST" | tr ',' ' '); do
    e=$(lower "$e"); e=${e%%:*}
    [ -z "$e" ] && continue
    [ "$e" = "*" ] && return 0
    case $e in .*) e=${e#.} ;; esac
    case $e in \*.*) e=${e#\*.} ;; esac
    [ "$h" = "$e" ] && return 0
    case $h in *".$e") return 0 ;; esac
  done
  return 1
}

cfg_quote() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Curl reads its proxy from a config file (mode 600), so a proxy password never shows in ps.
write_curl_configs() {
  umask 077
  {
    printf 'noproxy = "*"\n'
    [ -n "${CUSTOM_CA:-}" ] && printf 'cacert = "%s"\n' "$CUSTOM_CA"
    printf 'user-agent = "harness-delegate-preflight/%s"\n' "$VERSION"
  } > "$WORK/direct.cfg"
  if [ -n "$PROXY_URL" ]; then
    {
      printf 'proxy = "%s"\n' "$(cfg_quote "$PROXY_URL")"
      [ -n "${CUSTOM_CA:-}" ] && printf 'cacert = "%s"\n' "$CUSTOM_CA"
      printf 'user-agent = "harness-delegate-preflight/%s"\n' "$VERSION"
    } > "$WORK/proxy.cfg"
  fi
}

# path_for HOST: "proxy" if the delegate would reach HOST through the proxy, else "direct"
path_for() {
  if [ -n "$PROXY_URL" ] && ! in_no_proxy "$1"; then echo proxy; else echo direct; fi
}

# http_probe MODE URL [curl args...]
# Sets P_RC P_CODE P_PCODE P_IP P_TCONN P_TTLS P_TTOTAL P_REDIRS P_EFF P_ERR.
# The response is in $WORK/body, headers in $WORK/hdrs, curl -v output in $WORK/verbose.
http_probe() {
  local mode=$1 url=$2 cfg w; shift 2
  cfg="$WORK/direct.cfg"; [ "$mode" = proxy ] && cfg="$WORK/proxy.cfg"
  : > "$WORK/body"; : > "$WORK/hdrs"
  w=$(curl -K "$cfg" -sS -v -o "$WORK/body" -D "$WORK/hdrs" --connect-timeout "$T" -m "$((T * 2))" \
        -w '%{http_code}|%{http_connect}|%{remote_ip}|%{time_connect}|%{time_appconnect}|%{time_total}|%{num_redirects}|%{url_effective}' \
        "$@" "$url" 2>"$WORK/verbose")
  P_RC=$?
  IFS='|' read -r P_CODE P_PCODE P_IP P_TCONN P_TTLS P_TTOTAL P_REDIRS P_EFF <<EOF
$w
EOF
  P_ERR=$(grep '^curl: (' "$WORK/verbose" | tail -1 | sed 's/^curl: ([0-9]*) //')
  [ "$P_RC" != 0 ] && verbose "curl exit $P_RC: $P_ERR"
  return 0
}

hdr() { grep -i "^$1:" "$WORK/hdrs" | tail -1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r'; }
ms() { awk -v s="${1:-0}" 'BEGIN{printf "%d", s * 1000}'; }
html_title() { tr -d '\r\n' < "$WORK/body" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<.*/\1/p' | cut -c1-80; }

# resolve HOST: print its IP addresses, one per line
resolve() {
  local h=$1
  case $h in *[!0-9.]*) ;; *) echo "$h"; return 0 ;; esac
  if have getent; then
    with_timeout "$T" getent ahosts "$h" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
  elif have dscacheutil; then
    with_timeout "$T" dscacheutil -q host -a name "$h" 2>/dev/null | awk '/^ipv?6?_?address:/{print $2}' | awk '!seen[$0]++'
  elif have python3; then
    with_timeout "$T" python3 -c 'import socket,sys
for a in dict.fromkeys(i[4][0] for i in socket.getaddrinfo(sys.argv[1], 443)): print(a)' "$h" 2>/dev/null
  elif have nslookup; then
    with_timeout "$T" nslookup "$h" 2>/dev/null | awk '/^Address/ && !/#/{print $2}'
  fi
}

# tcp_probe HOST PORT: 0 open, 1 refused or unreachable, 2 timed out
tcp_probe() {
  with_timeout "$T" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" >/dev/null 2>&1
  local rc=$?
  [ $rc = 0 ] && return 0
  [ $rc -ge 124 ] && return 2
  return 1
}

# classify_issuer "ISSUER": prints public, intercept:<vendor> or unknown
classify_issuer() {
  local s v
  s=$(lower "$1")
  for v in zscaler netskope "palo alto" paloalto fortinet fortigate "blue coat" bluecoat symantec \
           broadcom "cisco umbrella" umbrella opendns forcepoint websense sophos "check point" checkpoint \
           mcafee skyhigh barracuda iboss menlo squid mitmproxy charles fiddler do_not_trust kaspersky \
           eset avast bitdefender untangle lightspeed "cato networks" "gateway ca" "trend micro" \
           contentkeeper smoothwall securly "ssl inspection" "ssl-inspection" inspection decrypt \
           firewall "proxy"; do
    case $s in *"$v"*) echo "intercept:$v"; return ;; esac
  done
  for v in digicert "google trust services" "let's encrypt" isrg amazon sectigo comodo usertrust \
           globalsign entrust godaddy starfield microsoft cloudflare identrust zerossl "ssl.com" \
           quovadis buypass baltimore geotrust rapidssl thawte certum harica actalis certainly; do
    case $s in *"$v"*) echo public; return ;; esac
  done
  echo unknown
}

tls_issuer() { grep -E '^\*[[:space:]]+issuer:' "$WORK/verbose" | head -1 | sed 's/^\*[[:space:]]*issuer:[[:space:]]*//'; }
tls_version() {   # from "SSL connection using TLSv1.3 / ..."; curl also logs record-layer versions
  grep -E 'SSL connection using|TLS connection using' "$WORK/verbose" | grep -oE 'TLSv1(\.[0-3])?' | head -1
}
issuer_short() {
  local o cn
  o=$(printf '%s' "$1" | sed -n 's/.*O[[:space:]]*=[[:space:]]*\([^;,/]*\).*/\1/p')
  cn=$(printf '%s' "$1" | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^;,/]*\).*/\1/p')
  if [ -n "$o" ] && [ -n "$cn" ]; then printf '%s (%s)' "$o" "$cn"; elif [ -n "$o$cn" ]; then printf '%s' "$o$cn"; else printf '%s' "$1"; fi
}

http_date_epoch() {
  LC_ALL=C date -u -d "$1" +%s 2>/dev/null && return
  LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S %Z' "$1" +%s 2>/dev/null
}

human_bytes() { awk -v b="${1:-0}" 'BEGIN{ if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.0f MB", b/1048576; else printf "%d KB", b/1024 }'; }

# ---------------------------------------------------------------------------------------
# Diagnosis: turn a failed probe into a reason and a fix
# ---------------------------------------------------------------------------------------
cloud_hint() {
  case ${CLOUD:-} in
    aws) printf 'On AWS: check the security group outbound rules and the subnet network ACL, and that a private subnet routes 0.0.0.0/0 to a NAT gateway.' ;;
    azure) printf 'On Azure: check the NSG outbound rules, and any route table that sends traffic to Azure Firewall or an NVA. Allow the host there.' ;;
    gcp) printf 'On GCP: check the VPC firewall egress rules, and that a VM without an external IP has Cloud NAT.' ;;
    *) printf 'Allow outbound TCP %s on your firewall, or route the traffic through a proxy (--proxy http://host:port).' "${1:-443}" ;;
  esac
}

EGRESS_STATE=""   # cached: ok, blocked
diagnose_egress() {
  [ -n "$EGRESS_STATE" ] && return
  http_probe direct "https://www.google.com/generate_204"
  if [ "$P_RC" = 0 ] && [ -n "$P_CODE" ] && [ "$P_CODE" != 000 ]; then EGRESS_STATE=ok; return; fi
  if tcp_probe 1.1.1.1 443; then EGRESS_STATE=ok; else EGRESS_STATE=blocked; fi
}

# explain MODE HOST: sets WHY (short reason) and FIX (what to do) from the last http_probe
explain() {
  local mode=$1 host=$2 port=${3:-443}
  WHY=""; FIX=""
  local via="direct"; [ "$mode" = proxy ] && via="through the proxy"
  if [ "$P_RC" = 28 ] && printf '%s' "$P_ERR" | grep -qi 'resolv'; then
    if [ "$mode" = proxy ]; then P_RC=5; else P_RC=6; fi
  fi
  # The proxy answered CONNECT with an error. Older curl exits 56 here, curl 8 exits 7.
  local pc=$P_PCODE
  case $pc in ''|000) pc=$(printf '%s' "$P_ERR" | sed -n 's/.*CONNECT tunnel failed, response \([0-9][0-9][0-9]\).*/\1/p') ;; esac
  if [ "$mode" = proxy ] && [ "$P_RC" != 0 ]; then
    case $pc in
      407) WHY="the proxy wants credentials (HTTP 407)"
           FIX="Pass them: --proxy http://USER:PASSWORD@$PX_HOST:$PX_PORT. The delegate needs them too: PROXY_USER and PROXY_PASSWORD (Helm: proxyUser, proxyPassword, base64)."
           return ;;
      403) WHY="the proxy blocked $host (HTTP 403 to CONNECT)"; FIX="Ask your proxy team to allow $host on port $port."; return ;;
      [45][0-9][0-9]) WHY="the proxy refused the tunnel (HTTP $pc)"; FIX="Ask your proxy team to allow CONNECT to $host:$port."; return ;;
    esac
  fi
  case $P_RC in
    5) WHY="can't resolve the proxy host"; FIX="Check the proxy host name: $PX_DISPLAY" ;;
    6) WHY="DNS lookup for $host failed"
       FIX="This machine can't resolve $host. See the DNS section above: check /etc/resolv.conf or your VPC/VNet
DNS settings, or ask whether a DNS filter blocks it." ;;
    7)
      # curl 8 says only "Could not connect to server"; the reason is in the -v log
      local why7; why7="$P_ERR $(grep -iE 'connect to .* failed|Connection refused|unreachable|No route' "$WORK/verbose" | tail -2)"
      if [ "$mode" = proxy ] && [ "$P_PCODE" = 000 ] && printf '%s' "$why7" | grep -q "$PX_HOST port $PX_PORT"; then
        WHY="can't connect to the proxy"; FIX="Nothing is listening at $PX_DISPLAY, or a firewall blocks it. Check the proxy host and port."
      else
        case $why7 in
          *[Rr]efused*) WHY="connection refused on port $port (a firewall is rejecting it)"
                        FIX="Something between here and $host actively rejects TCP $port. $(cloud_hint "$port")" ;;
          *[Uu]nreachable*|*"No route"*) WHY="no network route to $host"
                        FIX="This machine has no route for that address. $(cloud_hint "$port")" ;;
          *) WHY="couldn't connect ($P_ERR)"; FIX=$(cloud_hint "$port") ;;
        esac
      fi ;;
    28)
      if [ "$(ms "$P_TCONN")" = 0 ]; then
        if [ "$mode" = proxy ]; then WHY="timed out connecting to the proxy"; FIX="Can this machine reach $PX_HOST:$PX_PORT? Check the proxy address and any firewall in between."
        else
          WHY="timed out connecting on port $port (a firewall is silently dropping it)"
          diagnose_egress
          if [ "$EGRESS_STATE" = blocked ]; then
            FIX="This machine has no outbound internet access at all, not just to Harness. $(cloud_hint "$port")
If your network requires a proxy, rerun with --proxy http://host:port."
          else
            FIX="Other HTTPS sites work, so $host is blocked specifically. Add $host to your firewall or egress allowlist (TCP $port)."
          fi
        fi
      else
        WHY="connected, but the response timed out"; FIX="Something in the path accepts the connection and then stalls it: often a TLS-inspecting firewall or IPS. Exempt $host from inspection."
      fi ;;
    35) WHY="TLS handshake failed ${via}"; FIX="A firewall or proxy is breaking TLS to $host (often SNI filtering or TLS inspection). Allow $host without inspection." ;;
    51|58|60|77|83) WHY="TLS certificate not trusted"; FIX="" ;;   # handled by the caller, which looks up the issuer
    52) WHY="the server closed the connection without a reply"; FIX="Usually a firewall or IPS cutting the connection. Allow $host." ;;
    56|97)
      case $P_PCODE in
        407) WHY="the proxy wants credentials (HTTP 407)"
             FIX="Pass them: --proxy http://USER:PASSWORD@$PX_HOST:$PX_PORT. The delegate needs them too: PROXY_USER and PROXY_PASSWORD (Helm: proxyUser, proxyPassword, base64)." ;;
        403) WHY="the proxy blocked $host (HTTP 403 to CONNECT)"; FIX="Ask your proxy team to allow $host on port $port." ;;
        000|"") WHY="connection reset ${via}"; FIX="A firewall, IPS or proxy reset the connection, often because of an SNI or URL-category filter. Allow $host." ;;
        *) WHY="the proxy refused the tunnel (HTTP $P_PCODE)"; FIX="Ask your proxy team to allow CONNECT to $host:$port." ;;
      esac ;;
    0) WHY="HTTP $P_CODE"; FIX="" ;;
    *) WHY="curl error $P_RC: $P_ERR"; FIX="" ;;
  esac
}

# TLS inspection, after a probe that succeeded or failed on the certificate
INTERCEPT_SEEN=""; INTERCEPT_ISSUER=""
CA_FIX_K8S='kubectl create secret generic harness-delegate-ca -n NAMESPACE --from-file=ca.pem=/path/to/your-root-ca.pem
helm upgrade --install ... --set delegateCustomCa.secretName=harness-delegate-ca'
CA_FIX_DOCKER='docker run -u root -v /path/to/certs:/opt/harness-delegate/ca-bundle ...   (PEM files)'
ca_fix() {
  local k8s
  k8s=$(printf '%s' "$CA_FIX_K8S" | sed "s/NAMESPACE/$NAMESPACE/")
  printf 'Or ask your security team to exempt *.harness.io from TLS inspection.\nKubernetes:\n  %s\nDocker:\n  %s' \
    "$(printf '%s' "$k8s" | sed '2s/^/  /')" "$CA_FIX_DOCKER"
}

check_tls() {   # check_tls LABEL MODE HOST, after a successful probe
  local label=$1 mode=$2 host=$3 iss cls ver
  iss=$(tls_issuer); ver=$(tls_version)
  [ -z "$iss" ] && { info "$label" "${ver:-TLS} (couldn't read the certificate issuer)"; return; }
  cls=$(classify_issuer "$iss")
  if [ "$cls" != public ] && [ -n "${CUSTOM_CA:-}" ]; then
    INTERCEPT_SEEN=1; INTERCEPT_ISSUER=$(issuer_short "$iss")
    pass "$label" "${ver:+$ver, }issued by $(issuer_short "$iss") (TLS inspection), trusted through the delegate's custom CA"
    return
  fi
  case $cls in
    public) pass "$label" "${ver:+$ver, }issued by $(issuer_short "$iss")" ;;
    intercept:*)
      INTERCEPT_SEEN=1; INTERCEPT_ISSUER=$(issuer_short "$iss")
      warn "$label" "intercepted: issued by $(issuer_short "$iss"), not a public CA" \
        "Your network inspects TLS to $host. This machine trusts that CA, but the delegate
container has its own trust store and won't. Add the inspecting proxy's root CA to the delegate.
$(ca_fix)" ;;
    *)
      INTERCEPT_SEEN=1; INTERCEPT_ISSUER=$(issuer_short "$iss")
      warn "$label" "issued by $(issuer_short "$iss"), which isn't a public CA I recognize" \
        "This looks like TLS inspection. If it is, the delegate needs that root CA too.
$(ca_fix)" ;;
  esac
}

# After a certificate failure: retry without verification just to read who issued the certificate
explain_cert_failure() {
  local label=$1 mode=$2 url=$3 host=$4 iss
  http_probe "$mode" "$url" -k
  iss=$(tls_issuer)
  INTERCEPT_SEEN=1; INTERCEPT_ISSUER=$(issuer_short "${iss:-unknown}")
  fail "$label" "certificate not trusted: issued by $(issuer_short "${iss:-an unknown CA}")" \
    "Something between here and $host re-signs TLS with its own CA (TLS inspection). Neither this
machine nor the delegate trusts it. Add that root CA to the delegate:
$(ca_fix)"
}

# ---------------------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------------------
detect_cloud() {
  CLOUD=""; CLOUD_NAME=""
  local v p b
  v=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); p=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  b=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
  case "$v $p $b" in
    *[Aa]mazon*) CLOUD=aws; CLOUD_NAME="AWS EC2" ;;
    *Google*) CLOUD=gcp; CLOUD_NAME="Google Compute Engine" ;;
    *"Microsoft Corporation"*"Virtual Machine"*) CLOUD=azure; CLOUD_NAME="Azure VM" ;;
    *[Oo]racle*|*OracleCloud*) CLOUD=oci; CLOUD_NAME="Oracle Cloud" ;;
  esac
  [ -z "$CLOUD" ] && [ -r /sys/hypervisor/uuid ] && case $(cat /sys/hypervisor/uuid) in ec2*) CLOUD=aws; CLOUD_NAME="AWS EC2" ;; esac
}

# In the probe pod: the delegate's start.sh adds /opt/harness-delegate/ca-bundle/* to its trust
# store. The probe runs sleep instead, so add them to curl's CA bundle here.
load_delegate_ca() {
  local dir=/opt/harness-delegate/ca-bundle f n=0 sys=""
  [ -d "$dir" ] || return 0
  for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [ -r "$f" ] && { sys=$f; break; }; done
  : > "$WORK/ca.pem"
  [ -n "$sys" ] && cat "$sys" >> "$WORK/ca.pem"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    if grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null; then
      { cat "$f"; echo; } >> "$WORK/ca.pem"; n=$((n + $(grep -c 'BEGIN CERTIFICATE' "$f")))
    elif have openssl && openssl x509 -inform der -in "$f" >> "$WORK/ca.pem" 2>/dev/null; then n=$((n + 1)); fi
  done
  if [ "$n" -gt 0 ]; then
    CUSTOM_CA=$WORK/ca.pem
    info "Custom CA" "$n certificate(s) in $dir (delegateCustomCa), trusted here as the delegate trusts them"
  elif [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    warn "Custom CA" "$dir has files, but no certificate I can read" "The delegate reads PEM (.crt, .pem) or DER (.der, .cer) files. Check the secret's contents."
  fi
}

section_environment() {
  section "This machine"
  local os arch kern
  OS=$(uname -s); arch=$(uname -m); kern=$(uname -r)
  case $arch in x86_64|amd64) HOST_ARCH=amd64 ;; aarch64|arm64) HOST_ARCH=arm64 ;; *) HOST_ARCH=$arch ;; esac
  if [ "$OS" = Darwin ]; then os="macOS $(sw_vers -productVersion 2>/dev/null)"
  elif [ -r /etc/os-release ]; then os=$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-$NAME}")
  else os="$OS $kern"; fi
  detect_cloud
  info "Host" "$(hostname 2>/dev/null) - $os, $arch${CLOUD_NAME:+, $CLOUD_NAME}"
  local cv; cv=$(curl --version | awk 'NR==1{print $2}')
  [ "$IN_POD" = 0 ] && info "Tools" "bash ${BASH_VERSION%%(*}, curl $cv$(have kubectl && printf ', kubectl')$(have helm && printf ', helm')$(have docker && printf ', docker')$(have podman && printf ', podman')"
  if [ "$OS" = Darwin ] && [ "$IN_POD" = 0 ] && [ "$TARGET" != k8s ]; then
    info "Note" "macOS can't host the delegate itself; it runs it in a Linux container (Docker Desktop, Rancher Desktop)"
  fi
  [ "$IN_POD" = 1 ] && load_delegate_ca
}

section_resources() {
  section "Host resources"
  local cpus mem_kb avail_kb disk_kb arch
  case $HOST_ARCH in amd64|arm64) pass "CPU architecture" "$HOST_ARCH (the delegate image supports amd64 and arm64)" ;;
    *) fail "CPU architecture" "$HOST_ARCH" "The delegate image is published for amd64 and arm64 only." ;; esac
  if [ "$OS" = Darwin ]; then
    cpus=$(sysctl -n hw.ncpu 2>/dev/null); mem_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 )); avail_kb=""
  else
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
  fi
  if [ -n "$cpus" ]; then
    if [ "$cpus" -ge 2 ]; then pass "CPU" "$cpus cores (the delegate asks for 1)"
    else warn "CPU" "$cpus core" "The delegate asks for 1 CPU, which leaves nothing for the OS. Use 2 or more cores."; fi
  fi
  if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ]; then
    local mem_mb=$((mem_kb / 1024)) av_mb=""
    [ -n "$avail_kb" ] && av_mb=$((avail_kb / 1024))
    if [ "$mem_mb" -lt 2560 ]; then
      fail "Memory" "${mem_mb} MB total" "The delegate needs 2 GB for itself plus room for the OS. Use a machine with at least 4 GB."
    elif [ -n "$av_mb" ] && [ "$av_mb" -lt 2200 ]; then
      warn "Memory" "${mem_mb} MB total, only ${av_mb} MB free" "The delegate container takes 2 GB. Free some memory or use a bigger machine."
    elif [ "$mem_mb" -lt 3900 ]; then
      warn "Memory" "${mem_mb} MB total" "That fits the delegate's 2 GB, with little to spare. 4 GB or more is safer, and Terraform tasks need more."
    else
      pass "Memory" "${mem_mb} MB total${av_mb:+, ${av_mb} MB free}"
    fi
  fi
  local dir=${DOCKER_ROOT:-/}
  [ -d "$dir" ] || dir=/
  disk_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$disk_kb" ]; then
    local gb=$((disk_kb / 1048576))
    if [ "$gb" -lt 5 ]; then fail "Disk" "${gb} GB free on $dir" "The delegate image unpacks to about 3 GB, and tasks need scratch space. Free up at least 10 GB."
    elif [ "$gb" -lt 15 ]; then warn "Disk" "${gb} GB free on $dir" "Enough to start, but image upgrades and task workspaces need room. 20 GB or more is safer."
    else pass "Disk" "${gb} GB free on $dir"; fi
  fi
}

section_proxy() {
  section "Proxy"
  local src=""
  PROXY_URL=""; NOPROXY_LIST=""
  if [ "$DIRECT_ONLY" = 1 ]; then src=""
  elif [ -n "$PROXY_OPT" ]; then PROXY_URL=$PROXY_OPT; src="--proxy"
  elif [ -n "${HDPF_FWD_PROXY:-}" ]; then PROXY_URL=$HDPF_FWD_PROXY; src="forwarded from the workstation"
  elif [ -n "${PROXY_HOST:-}" ]; then
    PROXY_URL="$(lower "${PROXY_SCHEME:-http}")://${PROXY_HOST}${PROXY_PORT:+:$PROXY_PORT}"; src="PROXY_HOST"
    if [ -n "${PROXY_USER:-}" ]; then
      PROXY_URL="$(lower "${PROXY_SCHEME:-http}")://${PROXY_USER}:${PROXY_PASSWORD:-}@${PROXY_HOST}${PROXY_PORT:+:$PROXY_PORT}"
    fi
  elif [ -n "${https_proxy:-}" ]; then PROXY_URL=$https_proxy; src="https_proxy"
  elif [ -n "${HTTPS_PROXY:-}" ]; then PROXY_URL=$HTTPS_PROXY; src="HTTPS_PROXY"
  elif [ -n "${all_proxy:-}${ALL_PROXY:-}" ]; then PROXY_URL=${all_proxy:-$ALL_PROXY}; src="ALL_PROXY"
  elif [ -n "${http_proxy:-}${HTTP_PROXY:-}" ]; then PROXY_URL=${http_proxy:-$HTTP_PROXY}; src="http_proxy"
  fi
  if [ -n "$NOPROXY_OPT" ]; then NOPROXY_LIST=$NOPROXY_OPT
  elif [ -n "${HDPF_FWD_NOPROXY:-}" ]; then NOPROXY_LIST=$HDPF_FWD_NOPROXY
  else NOPROXY_LIST=${NO_PROXY:-${no_proxy:-}}; fi
  # From here on curl gets its proxy only from our config files.
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy

  if [ -n "$PROXY_URL" ]; then
    parse_proxy "$PROXY_URL"; PROXY_URL=$PX_URL
    if [ -z "$PX_PORT" ]; then
      fail "Proxy" "$PX_DISPLAY has no port" "Give the port: http://$PX_HOST:3128, for example. The delegate needs PROXY_PORT too."
      PROXY_URL=""
    else
      info "Proxy" "$PX_DISPLAY (from $src)"
      spin_start "Connecting to the proxy"
      if tcp_probe "$PX_HOST" "$PX_PORT"; then pass "Proxy reachable" "$PX_HOST:$PX_PORT accepts connections"
      else
        local rc=$?
        if [ $rc = 2 ]; then fail "Proxy reachable" "timed out connecting to $PX_HOST:$PX_PORT" "Check the proxy address, and any firewall between this machine and the proxy."
        else fail "Proxy reachable" "can't connect to $PX_HOST:$PX_PORT" "Nothing is listening there, or the name doesn't resolve. Check the proxy host and port."; fi
      fi
      [ -n "$NOPROXY_LIST" ] && info "No proxy for" "$NOPROXY_LIST"
    fi
  else
    if [ "$DIRECT_ONLY" = 1 ]; then info "Proxy" "none (--direct)"; else info "Proxy" "none set; connecting directly"; fi
  fi
  if [ "$OS" = Darwin ] && [ "$IN_POD" = 0 ] && have scutil; then
    local sc; sc=$(scutil --proxy 2>/dev/null)
    if printf '%s' "$sc" | grep -q 'ProxyAutoConfigEnable : 1'; then
      warn "macOS proxy" "a PAC file is set in System Settings" \
        "The delegate can't use a PAC file. Ask your network team for the explicit proxy host and port, and test it with --proxy."
    elif printf '%s' "$sc" | grep -q 'HTTPSEnable : 1' && [ -z "$PROXY_URL" ]; then
      local h p; h=$(printf '%s' "$sc" | awk '/HTTPSProxy :/{print $3}'); p=$(printf '%s' "$sc" | awk '/HTTPSPort :/{print $3}')
      warn "macOS proxy" "System Settings uses $h:$p, but this shell has no proxy" \
        "If the delegate's network needs that proxy too, rerun with --proxy http://$h:$p."
    fi
  fi
  write_curl_configs
}

section_dns() {
  section "DNS"
  local ns ips h
  if [ "$OS" = Darwin ] && have scutil; then
    ns=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | awk '!s[$0]++' | head -3 | tr '\n' ' ' | sed 's/ *$//')
  else
    ns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ *$//')
  fi
  info "Resolvers" "${ns:-none found}"
  DNS_HOSTS="$MGR_HOST"
  for h in $DNS_HOSTS; do
    spin_start "Resolving $h"
    ips=$(resolve "$h" | head -4 | paste -sd ' ' -)
    if [ -n "$ips" ]; then pass "Resolve $h" "$ips"
    elif [ "$(path_for "$h")" = proxy ]; then
      warn "Resolve $h" "doesn't resolve here; the proxy will resolve it" "Fine if the proxy handles DNS. If the manager checks below fail, check DNS."
    else
      local other; other=$(resolve www.google.com | head -1)
      if [ -n "$other" ]; then
        fail "Resolve $h" "no answer (other names resolve)" "Your DNS answers for other domains but not $h: a DNS filter or split-horizon zone is blocking it. Allow *.harness.io in DNS."
      else
        fail "Resolve $h" "no answer, and no other names resolve either" "This machine's DNS isn't working. Check the resolvers above (/etc/resolv.conf, or your VPC/VNet DNS settings)."
      fi
    fi
  done
}

# Discover which SaaS cluster an account lives on. Sets FOUND_BASE.
discover_cluster() {
  FOUND_BASE=""
  local b m h
  for b in $SAAS_MANAGERS; do
    h=${b#https://}; h=${h%%/*}
    m=$(path_for "$h")
    http_probe "$m" "$b/api/account/$ACCOUNT_ID/status" -m "$T"
    if [ "$P_RC" = 0 ] && grep -q '"resource":"ACTIVE"' "$WORK/body"; then FOUND_BASE=$b; return 0; fi
  done
  return 1
}

section_manager() {
  section "Harness manager ($MGR_BASE)"
  local mode health url age skew now srv
  mode=$(path_for "$MGR_HOST")
  MGR_MODE=$mode
  local via=""; [ "$mode" = proxy ] && via=" via proxy"

  # 1. The main check: HTTPS to /api/health along the delegate's path
  url="$MGR_BASE/api/health"
  spin_start "Connecting to $MGR_HOST$via"
  http_probe "$mode" "$url"
  MGR_OK=0
  if [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ] && grep -q healthy "$WORK/body"; then
    MGR_OK=1
    pass "HTTPS to $MGR_HOST$via" "healthy, $(ms "$P_TTOTAL") ms${P_IP:+ ($P_IP)}"
    local ttotal=$P_TTOTAL
    if [ "$MGR_SCHEME" = https ]; then check_tls "TLS certificate" "$mode" "$MGR_HOST"; fi
    # Clock skew against the server's Date header
    srv=$(http_date_epoch "$(hdr date)")
    now=$(date -u +%s)
    if [ -n "$srv" ]; then
      skew=$((now - srv)); age=${skew#-}
      if [ "$age" -le 60 ]; then pass "Clock" "within ${age}s of Harness"
      elif [ "$age" -le 300 ]; then warn "Clock" "${skew}s off Harness's clock" "Turn on time sync (chrony, systemd-timesyncd, or the cloud's NTP). Tokens are time-based."
      else fail "Clock" "${skew}s off Harness's clock" "The delegate authenticates with time-limited tokens, so a clock this far off gets rejected.
Turn on time sync: sudo timedatectl set-ntp true (or chrony), then check with: timedatectl"; fi
    fi
    awk -v t="$ttotal" 'BEGIN{exit !(t > 3)}' && warn "Latency" "$(ms "$ttotal") ms for one request" "Slow, but it works. A slow proxy or a long path to Harness makes tasks slower."
  elif [ "$P_RC" = 0 ]; then
    local title; title=$(html_title)
    if [ -n "$title" ] || ! grep -q '"resource"' "$WORK/body"; then
      fail "HTTPS to $MGR_HOST$via" "HTTP $P_CODE, and the reply isn't from Harness${title:+: \"$title\"}" \
        "Something in between answered instead of Harness: usually a proxy or web filter block page. Ask for $MGR_HOST to be allowed."
    else
      fail "HTTPS to $MGR_HOST$via" "HTTP $P_CODE from Harness" "Check the URL: $MGR_BASE"
    fi
  else
    case $P_RC in
      51|58|60|77|83) explain_cert_failure "HTTPS to $MGR_HOST$via" "$mode" "$url" "$MGR_HOST" ;;
      *) explain "$mode" "$MGR_HOST" "$MGR_PORT"; fail "HTTPS to $MGR_HOST$via" "$WHY" "$FIX" ;;
    esac
  fi

  # 2. If we went through a proxy, would direct work too? If we went direct and failed, would the env proxy have helped?
  if [ "$mode" = proxy ]; then
    spin_start "Trying $MGR_HOST without the proxy"
    http_probe direct "$url" --connect-timeout 4 -m 8
    if [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ]; then
      DIRECT_OK=1; info "Without the proxy" "also works: the delegate doesn't need a proxy for Harness"
    else
      DIRECT_OK=0; info "Without the proxy" "blocked, so the delegate must use the proxy (settings at the end)"
    fi
  fi

  [ "$MGR_OK" = 1 ] || { MGR_FAILED=1; return; }

  # 3. Account on this cluster
  if [ -n "$ACCOUNT_ID" ]; then
    spin_start "Looking up account $ACCOUNT_ID"
    http_probe "$mode" "$MGR_BASE/api/account/$ACCOUNT_ID/status"
    local res; res=$(grep -o '"resource":"[A-Z_]*"' "$WORK/body" | cut -d'"' -f4)
    if [ "$res" = ACTIVE ]; then pass "Account" "$ACCOUNT_ID is active on this cluster"
    elif grep -q ACCOUNT_DOES_NOT_EXIST "$WORK/body"; then
      spin_start "Account not here; looking for it on the other clusters"
      if discover_cluster && [ "$FOUND_BASE" != "$MGR_BASE" ]; then
        fail "Account" "$ACCOUNT_ID isn't on $MGR_BASE. It's on $FOUND_BASE" \
          "Point the delegate at the right cluster: MANAGER_HOST_AND_PORT=$FOUND_BASE (Helm: managerEndpoint).
Copy the install command from Harness (Project Settings > Delegates > New Delegate), which has the right URL."
        WRONG_CLUSTER=$FOUND_BASE
      else
        fail "Account" "$ACCOUNT_ID wasn't found on any Harness SaaS cluster" "Check the account ID: it's in your browser's address bar after /account/."
      fi
    elif [ -n "$res" ]; then
      fail "Account" "$ACCOUNT_ID is $res" "The account isn't active. Talk to your Harness account team."
    else
      warn "Account" "couldn't confirm (HTTP $P_CODE)" ""
    fi
  else
    skip "Account" "pass --account-id to confirm the account is on this cluster"
  fi

  # 4. Log service
  spin_start "Checking the log service"
  http_probe "$mode" "$MGR_BASE/log-service/healthz"
  if [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ]; then pass "Log service" "$MGR_BASE/log-service/ is reachable"
  else explain "$mode" "$MGR_HOST"; fail "Log service" "${WHY:-HTTP $P_CODE}" "${FIX:-The delegate streams task logs here. Allow $MGR_BASE/log-service/ through your proxy or firewall.}"; fi

  # 5. WebSocket: the delegate gets its tasks over one unless pollForTasks is true
  if [ -n "$ACCOUNT_ID" ] && [ -z "${WRONG_CLUSTER:-}" ]; then
    spin_start "Opening a WebSocket"
    local key p code101=0 sawcode=""
    key=$(head -c 16 /dev/urandom | base64 | tr -d '\n')
    for p in /api/stream/delegate /stream/delegate; do
      http_probe "$mode" "$MGR_BASE$p/$ACCOUNT_ID" --http1.1 -m 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $key"
      [ "$P_CODE" = 101 ] && { code101=1; break; }
      case " $sawcode " in *" $P_CODE "*) ;; *) sawcode="$sawcode $P_CODE" ;; esac
    done
    if [ "$code101" = 1 ]; then pass "WebSocket" "upgrade accepted (HTTP 101)"
    elif [ "$mode" = proxy ] || [ -n "$INTERCEPT_SEEN" ]; then
      WS_FAILED=1
      warn "WebSocket" "upgrade refused (HTTP${sawcode})" "A proxy or TLS inspection in the path doesn't pass WebSockets, which the delegate uses to get tasks.
Allow WebSocket upgrades to $MGR_HOST, or make the delegate poll instead: POLL_FOR_TASKS=true (Helm: --set pollForTasks=true)."
    else
      info "WebSocket" "couldn't confirm on this cluster (HTTP${sawcode}); if the delegate logs \"Socket is not open\", set POLL_FOR_TASKS=true"
    fi
  else
    skip "WebSocket" "needs --account-id"
  fi

  # 6. Optional: Google Cloud Logging, which the delegate sends its own logs to
  spin_start "Checking logging.googleapis.com"
  http_probe "$(path_for logging.googleapis.com)" "https://logging.googleapis.com/" -m "$T"
  if [ "$P_RC" = 0 ]; then pass "logging.googleapis.com" "reachable (optional: the delegate's own logs go here)"
  else info "logging.googleapis.com" "not reachable. Optional: set STACK_DRIVER_LOGGING_ENABLED=false to stop the delegate trying"; fi
}

# ---------------------------------------------------------------------------------------
# Image registry: can we fetch the delegate image's manifest and a layer?
# ---------------------------------------------------------------------------------------
# json_objects DEPTH < file: print each JSON object/array that starts at nesting DEPTH, one per line
json_objects() {
  awk -v want="$1" 'BEGIN{RS="\001"} {
    s=$0; d=0; buf=""; ins=0; esc=0; n=length(s)
    for (i=1; i<=n; i++) {
      c=substr(s,i,1)
      if (ins) { if (d>=want) buf=buf c; if (esc) esc=0; else if (c=="\\") esc=1; else if (c=="\"") ins=0; continue }
      if (c=="\"") { ins=1; if (d>=want) buf=buf c; continue }
      if (c=="{" || c=="[") { d++; if (d>=want) buf=buf c; continue }
      if (c=="}" || c=="]") { if (d>=want) buf=buf c; if (d==want) { print buf; buf="" } d--; continue }
      if (d>=want && c!=" " && c!="\n" && c!="\r" && c!="\t") buf=buf c
    }
  }'
}
jfield() { grep -oE "\"$1\":(\"[^\"]*\"|[0-9]+)" | head -1 | cut -d: -f2- | tr -d '"'; }

ACCEPT_MANIFEST='Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# parse_image REF: sets IMG_REG (API host), IMG_REPO, IMG_TAG
parse_image() {
  local ref=$1 first rest
  IMG_TAG="latest"
  case $ref in *@sha256:*) IMG_TAG=${ref#*@}; ref=${ref%@*} ;; esac
  first=${ref%%/*}
  case $first in
    *.*|*:*|localhost) IMG_REG=$first; rest=${ref#*/} ;;
    *) IMG_REG=docker.io; rest=$ref ;;
  esac
  case $rest in *:*) [ "$IMG_TAG" = latest ] && IMG_TAG=${rest##*:}; rest=${rest%:*} ;; esac
  IMG_REPO=$rest
  if [ "$IMG_REG" = docker.io ] || [ "$IMG_REG" = index.docker.io ]; then
    IMG_REG=registry-1.docker.io
    case $IMG_REPO in */*) ;; *) IMG_REPO="library/$IMG_REPO" ;; esac
  fi
}

# registry_auth: get an anonymous pull token if the registry wants one. Sets AUTH_HDR (a file) or AUTH_STATE
registry_auth() {
  local reg=$1 repo=$2 mode=$3 www realm service tok
  AUTH_HDR=""; AUTH_STATE=""
  http_probe "$mode" "https://$reg/v2/"
  REG_RC=$P_RC; REG_CODE=$P_CODE
  [ "$P_RC" = 0 ] || return 1
  [ "$P_CODE" = 200 ] && { AUTH_STATE=open; return 0; }
  www=$(hdr www-authenticate)
  case $(lower "$www") in
    bearer*)
      realm=$(printf '%s' "$www" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
      service=$(printf '%s' "$www" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
      local th; th=${realm#https://}; th=${th%%/*}
      http_probe "$(path_for "$th")" "$realm?scope=repository:$repo:pull${service:+&service=$service}" -G
      if [ "$P_RC" != 0 ]; then AUTH_STATE=tokenfail; return 1; fi
      tok=$(grep -oE '"(token|access_token)":"[^"]*"' "$WORK/body" | head -1 | cut -d'"' -f4)
      if [ -z "$tok" ]; then AUTH_STATE=private; return 0; fi
      umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$WORK/auth.hdr"; AUTH_HDR="$WORK/auth.hdr"
      AUTH_STATE=token ;;
    basic*) AUTH_STATE=private ;;
    *) AUTH_STATE=open ;;
  esac
  return 0
}

reg_get() {   # reg_get MODE URL [curl args]
  local mode=$1 url=$2; shift 2
  if [ -n "$AUTH_HDR" ]; then http_probe "$mode" "$url" -H "@$AUTH_HDR" "$@"; else http_probe "$mode" "$url" "$@"; fi
}

latest_delegate_tag() {   # from the registry's tag list; uses the current auth
  local mode=$1
  reg_get "$mode" "https://$IMG_REG/v2/$IMG_REPO/tags/list"
  [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ] || return 1
  grep -oE '"[0-9]{2}\.[0-9]{2}\.[0-9]{5}"' "$WORK/body" | tr -d '"' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

# check_image LABEL IMAGE ARCH: registry API, manifest, and a sample of the biggest layer
check_image() {
  local label=$1 image=$2 arch=$3 mode digest objs o man size big bigsize total=0
  parse_image "$image"
  mode=$(path_for "$IMG_REG")
  local via=""; [ "$mode" = proxy ] && via=" via proxy"
  spin_start "Contacting $IMG_REG$via"
  if ! registry_auth "$IMG_REG" "$IMG_REPO" "$mode"; then
    if [ "${AUTH_STATE:-}" = tokenfail ]; then
      explain "$mode" "auth server"; fail "$label" "can't get a pull token: $WHY" "${FIX:-The registry token server is blocked. Allow it too.}"
    else
      case $REG_RC in 51|58|60|77|83) explain_cert_failure "$label" "$mode" "https://$IMG_REG/v2/" "$IMG_REG" ;;
        *) explain "$mode" "$IMG_REG"; fail "$label" "can't reach $IMG_REG$via: $WHY" "$FIX" ;; esac
    fi
    return 1
  fi
  if [ "$AUTH_STATE" = private ]; then
    warn "$label" "$IMG_REG wants credentials; can't test the pull anonymously" \
      "If this is your own mirror, make sure the delegate has a pull secret (Helm: imagePullSecret)."
    return 0
  fi
  if [ "$IMG_TAG" = "@@latest" ]; then
    IMG_TAG=$(latest_delegate_tag "$mode")
    [ -n "$IMG_TAG" ] || IMG_TAG=$FALLBACK_TAG
    RESOLVED_TAG=$IMG_TAG
  fi
  spin_start "Fetching the $IMG_REPO:$IMG_TAG manifest"
  if [ "$IMG_REG" = registry-1.docker.io ]; then   # HEAD doesn't count against Docker Hub's pull limit
    reg_get "$mode" "https://$IMG_REG/v2/$IMG_REPO/manifests/$IMG_TAG" -I -H "$ACCEPT_MANIFEST"
    local rl; rl=$(hdr ratelimit-remaining); rl=${rl%%;*}
    if [ -n "$rl" ] && [ "$rl" -lt 10 ]; then
      warn "Docker Hub pull limit" "$rl pulls left this window for this IP" "Anonymous pulls are rate-limited per IP. Log in to Docker Hub, or use Harness's GAR image: $DEFAULT_GAR_REPO"
    elif [ -n "$rl" ]; then info "Docker Hub pull limit" "$rl pulls left this window (anonymous, per IP)"; fi
  fi
  reg_get "$mode" "https://$IMG_REG/v2/$IMG_REPO/manifests/$IMG_TAG" -H "$ACCEPT_MANIFEST"
  if [ "$P_RC" != 0 ]; then explain "$mode" "$IMG_REG"; fail "$label" "manifest: $WHY" "$FIX"; return 1; fi
  case $P_CODE in
    200) ;;
    404) fail "$label" "$IMG_REPO:$IMG_TAG not found on $IMG_REG" "Check the image name and tag."; return 1 ;;
    401|403) warn "$label" "$IMG_REG refused an anonymous pull (HTTP $P_CODE)" "The delegate needs a pull secret for this registry."; return 0 ;;
    429) fail "$label" "rate-limited by $IMG_REG (HTTP 429)" "Docker Hub limits anonymous pulls per IP. Use the GAR image ($DEFAULT_GAR_REPO) or authenticate."; return 1 ;;
    *) fail "$label" "manifest request: HTTP $P_CODE" ""; return 1 ;;
  esac
  cp "$WORK/body" "$WORK/manifest.json"
  if grep -q '"manifests"' "$WORK/manifest.json"; then
    digest=""
    while IFS= read -r o; do
      case $o in *"\"architecture\":\"$arch\""*'"os":"linux"'*|*'"os":"linux"'*"\"architecture\":\"$arch\""*)
        digest=$(printf '%s' "$o" | jfield digest); break ;; esac
    done <<EOF
$(json_objects 3 < "$WORK/manifest.json")
EOF
    if [ -z "$digest" ]; then
      fail "$label" "no linux/$arch build of $IMG_REPO:$IMG_TAG" "The image doesn't support this CPU architecture."
      return 1
    fi
    reg_get "$mode" "https://$IMG_REG/v2/$IMG_REPO/manifests/$digest" -H "$ACCEPT_MANIFEST"
    [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ] || { fail "$label" "couldn't fetch the linux/$arch manifest (HTTP $P_CODE)" ""; return 1; }
    cp "$WORK/body" "$WORK/manifest.json"
  fi
  # Layers: the objects at depth 3 that have a digest and a size
  big=""; bigsize=0
  while IFS= read -r o; do
    size=$(printf '%s' "$o" | jfield size); digest=$(printf '%s' "$o" | jfield digest)
    [ -n "$size" ] && [ -n "$digest" ] || continue
    total=$((total + size))
    [ "$size" -gt "$bigsize" ] && { bigsize=$size; big=$digest; }
  done <<EOF
$(json_objects 3 < "$WORK/manifest.json")
EOF
  pass "$label" "$IMG_REG/$IMG_REPO:$IMG_TAG, linux/$arch, $(human_bytes "$total") to pull"
  # Fetch the first KB of the biggest layer. Registries often redirect to a CDN on another host.
  if [ -n "$big" ]; then
    spin_start "Downloading a sample of a layer"
    reg_get "$mode" "https://$IMG_REG/v2/$IMG_REPO/blobs/$big" -L -r 0-1023
    local eh; eh=${P_EFF#*://}; eh=${eh%%/*}
    if [ "$P_RC" = 0 ] && { [ "$P_CODE" = 206 ] || [ "$P_CODE" = 200 ]; }; then
      if [ "$eh" != "$IMG_REG" ]; then pass "Layer download" "works; layers come from $eh"
      else pass "Layer download" "works"; fi
    else
      explain "$mode" "${eh:-$IMG_REG}"
      fail "Layer download" "layers come from ${eh:-another host}: ${WHY:-HTTP $P_CODE}" \
        "The registry API works, but the layer download host ${eh:-} is blocked. Allow it too.${FIX:+
$FIX}"
      return 1
    fi
  fi
  return 0
}

section_registry() {
  section "Delegate image"
  local arch=${NODE_ARCH:-${DOCKER_ARCH:-$HOST_ARCH}}
  case $arch in amd64|arm64) ;; *) arch=amd64 ;; esac
  local default=0 image=$IMAGE
  if [ -z "$image" ]; then default=1; image="$DEFAULT_GAR_REPO:@@latest"; fi
  RESOLVED_TAG=""
  if check_image "Pull from registry" "$image" "$arch"; then
    REG_OK=1
    [ "$default" = 1 ] && IMAGE="$DEFAULT_GAR_REPO:${RESOLVED_TAG:-$FALLBACK_TAG}"
  else
    REG_OK=0
    if [ "$default" = 1 ]; then
      [ -n "$RESOLVED_TAG" ] || RESOLVED_TAG=$FALLBACK_TAG
      IMAGE="$DEFAULT_GAR_REPO:$RESOLVED_TAG"
    fi
    if [ "$default" = 1 ] && [ "${MGR_OK:-0}" != 1 ]; then
      skip "Docker Hub instead" "not tried: fix the network problem above first"
    elif [ "$default" = 1 ]; then
      if check_image "Docker Hub instead" "$DEFAULT_DH_REPO:$RESOLVED_TAG" "$arch"; then
        ALT_IMAGE="$DEFAULT_DH_REPO:$RESOLVED_TAG"
        hint "Google Artifact Registry is blocked, but Docker Hub works. Install with
--set delegateDockerImage=$ALT_IMAGE (Docker: use that image name)."
      fi
    fi
  fi
  if [ "$TARGET" = k8s ]; then
    spin_start "Checking the Helm chart repo"
    http_probe "$(path_for app.harness.io)" "$HELM_REPO_URL/index.yaml"
    if [ "$P_RC" = 0 ] && [ "$P_CODE" = 200 ] && grep -q harness-delegate-ng "$WORK/body"; then
      pass "Helm chart repo" "$HELM_REPO_URL"
    else
      explain "$(path_for app.harness.io)" app.harness.io
      fail "Helm chart repo" "${WHY:-HTTP $P_CODE}" "helm repo add needs $HELM_REPO_URL. ${FIX:-Allow it, or download the chart somewhere that can reach it.}"
    fi
  fi
}

section_extra() {
  [ -n "$EXTRA_CHECKS" ] || return 0
  section "Your other endpoints"
  local e host port mode
  for e in $EXTRA_CHECKS; do
    e=${e#*://}; e=${e%%/*}
    host=${e%%:*}; port=443; case $e in *:*) port=${e##*:} ;; esac
    if [ "$port" = 443 ]; then
      mode=$(path_for "$host")
      spin_start "Connecting to $host"
      http_probe "$mode" "https://$host/" -m "$T"
      if [ "$P_RC" = 0 ]; then pass "$host:443" "reachable (HTTP $P_CODE)$( [ "$mode" = proxy ] && printf ' via proxy')"
        check_tls "  TLS ($host)" "$mode" "$host"
      else
        case $P_RC in 51|58|60|77|83) explain_cert_failure "$host:443" "$mode" "https://$host/" "$host" ;;
          *) explain "$mode" "$host" 443; fail "$host:443" "$WHY" "$FIX" ;; esac
      fi
    else
      spin_start "Connecting to $host:$port"
      tcp_probe "$host" "$port"
      case $? in
        0) pass "$host:$port" "TCP connect works (direct)" ;;
        2) fail "$host:$port" "timed out (direct)" "A firewall is dropping TCP $port to $host. $(cloud_hint "$port")" ;;
        *) if [ -z "$(resolve "$host" | head -1)" ]; then fail "$host:$port" "doesn't resolve" "Check the name, and DNS."
           else fail "$host:$port" "refused (direct)" "Nothing listens there, or a firewall rejects TCP $port."; fi ;;
      esac
    fi
  done
}

# ---------------------------------------------------------------------------------------
# Docker host
# ---------------------------------------------------------------------------------------
section_docker() {
  section "Container runtime"
  local cli="" outp rc ver arch root hp np
  if have docker; then cli=docker; elif have podman; then cli=podman; fi
  if [ -z "$cli" ]; then
    fail "Docker" "not installed" "Install Docker Engine (https://docs.docker.com/engine/install/) or Podman. The delegate runs as a container."
    return
  fi
  spin_start "Asking $cli for its status"
  if [ "$cli" = docker ]; then
    outp=$(with_timeout 20 docker info --format '{{.ServerVersion}}|{{.Architecture}}|{{.DockerRootDir}}|{{.HTTPSProxy}}|{{.NoProxy}}|{{.OperatingSystem}}' 2>&1); rc=$?
  else
    outp=$(with_timeout 20 podman info --format '{{.Version.Version}}|{{.Host.Arch}}|{{.Store.GraphRoot}}|||{{.Host.Distribution.Distribution}}' 2>&1); rc=$?
  fi
  if [ $rc != 0 ] || printf '%s' "$outp" | grep -qiE 'permission denied|cannot connect|is the docker daemon running|error'; then
    case $outp in
      *[Pp]ermission\ denied*) fail "$cli" "this user can't talk to the Docker daemon" "Add the user to the docker group (sudo usermod -aG docker \$USER, then log in again), or run the delegate with sudo." ;;
      *) fail "$cli" "the daemon isn't running or doesn't answer" "Start it: sudo systemctl enable --now docker   (macOS: start Docker Desktop or Rancher Desktop)" ;;
    esac
    verbose "$(printf '%s' "$outp" | tail -2)"
    return
  fi
  IFS='|' read -r ver arch root hp np osname <<EOF
$(printf '%s' "$outp" | tail -1)
EOF
  pass "$cli" "$ver on $osname, $arch"
  case $arch in x86_64|amd64) DOCKER_ARCH=amd64 ;; aarch64|arm64) DOCKER_ARCH=arm64 ;; *) DOCKER_ARCH=$arch ;; esac
  [ -n "$root" ] && DOCKER_ROOT=$root
  # The daemon pulls images with its own proxy settings, not this shell's
  if [ "$cli" = docker ]; then
    local need_proxy=0
    if [ -n "$PROXY_URL" ] && [ -n "${IMG_REG:-}" ] && [ "$(path_for "$IMG_REG")" = proxy ]; then
      http_probe direct "https://$IMG_REG/v2/" --connect-timeout 4 -m 8
      [ "$P_RC" = 0 ] || need_proxy=1
    fi
    if [ "$need_proxy" = 1 ]; then
      if [ -z "$hp" ]; then
        fail "Docker daemon proxy" "none set, but this network needs one" \
          "docker pull uses the daemon's proxy, not your shell's. Configure it:
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Service]\\nEnvironment=\"HTTPS_PROXY=$PX_DISPLAY\" \"NO_PROXY=localhost,127.0.0.1\"\\n' | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf
sudo systemctl daemon-reload && sudo systemctl restart docker"
      else pass "Docker daemon proxy" "$(printf '%s' "$hp" | sed 's#://\([^:@/]*\):[^@]*@#://\1:****@#')"; fi
    elif [ -n "$hp" ]; then info "Docker daemon proxy" "$(printf '%s' "$hp" | sed 's#://\([^:@/]*\):[^@]*@#://\1:****@#')"; fi
  fi
  if [ "$DO_PULL" = 1 ] && [ -n "$IMAGE" ]; then
    spin_start "Pulling $IMAGE (about 1 GB; this takes a while)"
    local t0 t1; t0=$(date +%s)
    outp=$(with_timeout 900 "$cli" pull "$IMAGE" 2>&1); rc=$?
    t1=$(date +%s)
    if [ $rc = 0 ]; then pass "$cli pull" "$IMAGE in $((t1 - t0))s"
    else fail "$cli pull" "$(printf '%s' "$outp" | tail -1 | cut -c1-150)" "The daemon's network path or proxy can't reach the registry. Check the daemon proxy, and any registry mirror in /etc/docker/daemon.json."; fi
  else
    skip "$cli pull" "not tried (use --pull to pull the image for real)"
  fi
}

# ---------------------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------------------
k() { with_timeout 25 "${KUBECTL[@]}" --request-timeout=15s "$@"; }

to_mib() {   # Kubernetes quantity to MiB
  awk -v q="$1" 'BEGIN{
    n=q; sub(/[A-Za-z]+$/,"",n); u=substr(q, length(n)+1)
    f["Ki"]=1/1024; f["Mi"]=1; f["Gi"]=1024; f["Ti"]=1048576; f["k"]=1000/1048576; f["M"]=1000000/1048576; f["G"]=1000000000/1048576; f[""]=1/1048576
    printf "%d", n * f[u] }'
}

# kjp FILE JSONPATH: read a field from a local manifest, without asking the cluster
# --local never talks to the cluster, but kubectl still tries the kubeconfig's server first (5s when it is down)
kjp() { KUBECONFIG=/dev/null kubectl patch --local -f "$1" --type merge -p '{}' -o jsonpath="$2" 2>/dev/null; }

# Render the delegate chart with the user's values, as a throwaway release: our own resource
# names, a dummy token, and no upgrader or autoscaler.
helm_render() {   # helm_render OUTFILE
  local a hargs
  hargs=(template "$HELM_REL")
  if [ -n "$HELM_CHART" ]; then hargs+=("$HELM_CHART"); else hargs+=(harness-delegate-ng --repo "$HELM_REPO_URL"); fi
  [ -n "$HELM_CHART_VERSION" ] && hargs+=(--version "$HELM_CHART_VERSION")
  hargs+=(--namespace "$NAMESPACE")
  for a in "${HELM_VALUES[@]}"; do hargs+=(-f "$a"); done
  for a in "${HELM_SETS[@]}"; do hargs+=(--set "$a"); done
  hargs+=(--set "fullnameOverride=$HELM_REL" --set delegateToken=preflight-not-a-real-token
         --set existingDelegateToken= --set upgrader.enabled=false --set autoscaling.enabled=false)
  with_timeout 120 helm "${hargs[@]}" > "$1" 2> "$WORK/helm.err"
}

# Split a render into one file per object: $HELM_DIR/<Kind>-<name>.yaml, namespace removed
helm_split() {
  awk -v d="$HELM_DIR" '
    function flush() { if (kind != "" && name != "") { f = d "/" kind "-" name ".yaml"; printf "%s", buf > f; close(f) }
                       buf = ""; kind = ""; name = "" }
    /^---/ { flush(); next }
    /^kind: / && kind == "" { kind = $2 }
    /^  name: / && name == "" { name = $2; gsub(/"/, "", name) }
    /^  namespace: / { next }
    { buf = buf $0 "\n" }
    END { flush() }' "$1"
}

section_helm_values() {
  section "Helm values"
  local f v="" chart
  for f in "${HELM_VALUES[@]}"; do v="$v $f"; done
  [ "${#HELM_SETS[@]}" -gt 0 ] && v="$v, ${#HELM_SETS[@]} --set"
  info "Values" "${v# }${HELM_CHART:+ (chart $HELM_CHART)}"
  if ! have helm || ! have kubectl; then
    fail "Helm values" "needs helm and kubectl on this machine to render them" "Install both, or run without --values for a plain probe pod."
    HELM_MODE=0; return
  fi
  HELM_DIR=$WORK/helm; mkdir -p "$HELM_DIR"
  spin_start "Rendering the delegate chart with your values"
  if ! helm_render "$HELM_DIR/render.yaml"; then
    fail "Chart" "helm template failed: $(grep -v '^[[:space:]]*$' "$WORK/helm.err" | tail -1 | cut -c1-160)" \
      "Check the values. If this machine can't reach $HELM_REPO_URL, mirror the chart and pass --chart."
    HELM_MODE=0; return
  fi
  helm_split "$HELM_DIR/render.yaml"
  local dep="$HELM_DIR/Deployment-$HELM_REL.yaml" cm="$HELM_DIR/ConfigMap-$HELM_REL.yaml"
  if [ ! -f "$dep" ] || [ ! -f "$cm" ]; then
    fail "Chart" "the render has no delegate Deployment and ConfigMap" "Is --chart the Harness delegate chart (harness-delegate-ng)?"
    HELM_MODE=0; return
  fi
  chart=$(grep -m1 'helm.sh/chart:' "$HELM_DIR/render.yaml" | awk '{print $2}')
  pass "Chart" "${chart:-harness-delegate-ng} renders with your values"

  HV_ACCT=$(kjp "$cm" '{.data.ACCOUNT_ID}'); HV_MGR=$(kjp "$cm" '{.data.MANAGER_HOST_AND_PORT}')
  # An unset value renders as null (or <no value> on older Helm)
  case $HV_ACCT in null|'<no value>') HV_ACCT="" ;; esac
  case $HV_MGR in null|'<no value>') HV_MGR="" ;; esac
  HV_NAME=$(kjp "$dep" '{.spec.template.metadata.labels.harness\.io/name}')
  HV_POLL=$(kjp "$cm" '{.data.POLL_FOR_TASKS}')
  HV_IMAGE=$(kjp "$dep" '{.spec.template.spec.containers[0].image}')
  HV_CA=$(kjp "$dep" '{.spec.template.spec.volumes[?(@.name=="custom-certs")].secret.secretName}')
  HV_PROXY=""
  if [ -f "$HELM_DIR/ConfigMap-$HELM_REL-proxy.yaml" ]; then
    HV_PROXY=$(kjp "$HELM_DIR/ConfigMap-$HELM_REL-proxy.yaml" '{.data.PROXY_HOST}')
    [ -n "$HV_PROXY" ] && HV_PROXY="$(kjp "$HELM_DIR/ConfigMap-$HELM_REL-proxy.yaml" '{.data.PROXY_SCHEME}' | tr '[:upper:]' '[:lower:]')://$HV_PROXY:$(kjp "$HELM_DIR/ConfigMap-$HELM_REL-proxy.yaml" '{.data.PROXY_PORT}')"
  fi
  local pxauth=""
  [ -n "$HV_PROXY" ] && [ -n "$(kjp "$HELM_DIR/Secret-$HELM_REL-proxy.yaml" '{.data.PROXY_USER}')" ] && pxauth=", with a user and password"
  info "Manager" "${HV_MGR:-none} (managerEndpoint)"
  info "Account" "${HV_ACCT:-none} (accountId)"
  info "Image" "$HV_IMAGE"
  info "Proxy" "${HV_PROXY:-none}$pxauth (proxyHost)"
  [ -n "$HV_CA" ] && info "Custom CA" "secret $HV_CA (delegateCustomCa)"
  [ "$HV_POLL" = true ] && info "Poll for tasks" "on (pollForTasks), so the delegate doesn't need the WebSocket"

  # The values are what the delegate will use, so they're what gets tested
  if [ -n "$HV_ACCT" ]; then
    if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "$HV_ACCT" ]; then
      fail "accountId" "your values have $HV_ACCT, but --account-id is $ACCOUNT_ID" "The delegate uses the one in the values. Testing $HV_ACCT."
    fi
    ACCOUNT_ID=$HV_ACCT
  else
    HV_FIX="${HV_FIX}accountId: ${ACCOUNT_ID:-<your account ID>}
"
    fail "accountId" "not in your values" "The delegate can't register without it. Add accountId: ${ACCOUNT_ID:-<your account ID>}."
  fi
  if [ -n "$HV_MGR" ]; then
    [ -n "$URL" ] && [ "${URL%/}" != "${HV_MGR%/}" ] && info "Harness URL" "testing managerEndpoint from your values, not --url $URL"
    URL=$HV_MGR
  fi
  [ "$IMAGE_CLI" = 1 ] || IMAGE=$HV_IMAGE
}

section_k8s() {
  section "Kubernetes cluster"
  if ! have kubectl; then
    fail "kubectl" "not installed" "Install kubectl and point it at the cluster: https://kubernetes.io/docs/tasks/tools/"
    return 1
  fi
  [ -n "$KCONTEXT" ] && KUBECTL=(kubectl --context "$KCONTEXT")
  local ctx server ver outp
  ctx=$("${KUBECTL[@]}" config current-context 2>/dev/null); [ -n "$KCONTEXT" ] && ctx=$KCONTEXT
  if [ -z "$ctx" ]; then fail "kubectl context" "none set" "Pick the cluster: kubectl config use-context <name>, or pass --context."; return 1; fi
  server=$("${KUBECTL[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  info "Context" "$ctx ($server)"
  spin_start "Contacting the API server"
  outp=$(k get --raw /version 2>&1)
  if [ $? != 0 ]; then
    fail "API server" "$(printf '%s' "$outp" | tail -1 | cut -c1-140)" "kubectl can't reach the cluster. Check your VPN, kubeconfig and credentials."
    return 1
  fi
  ver=$(printf '%s' "$outp" | grep -o '"gitVersion": *"[^"]*"' | cut -d'"' -f4)
  local dist=""
  case $ver in *-eks-*) dist="EKS" ;; *-gke.*) dist="GKE" ;; *+k3s*) dist="k3s" ;; *+rke2*) dist="RKE2" ;; esac
  if k get --raw /apis/security.openshift.io/v1 >/dev/null 2>&1; then dist="OpenShift"; fi
  pass "API server" "Kubernetes $ver${dist:+ ($dist)}"
  local minor; minor=$(printf '%s' "$ver" | sed -n 's/^v1\.\([0-9]*\).*/\1/p')
  [ -n "$minor" ] && [ "$minor" -lt 23 ] && warn "Kubernetes version" "$ver is old" "Kubernetes this old is out of support. The delegate chart is tested on current releases."
  if [ "$dist" = OpenShift ]; then
    warn "OpenShift" "the delegate runs as root by default" "Grant its service account the anyuid SCC: oc adm policy add-scc-to-user anyuid -z <delegate-name> -n $NAMESPACE"
  fi

  # Nodes
  spin_start "Listing nodes"
  outp=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}{.status.allocatable.memory}{"\t"}{.status.allocatable.cpu}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.spec.providerID}{"\t"}{.spec.unschedulable}{"\n"}{end}' 2>&1)
  if [ $? != 0 ]; then
    warn "Nodes" "can't list nodes ($(printf '%s' "$outp" | tail -1 | cut -c1-80))" "Your account may be namespace-scoped. The probe pod below still tests the network."
  else
    local total=0 ready=0 big=0 archs="" prov="" name a mem cpu rdy pid unsched
    while IFS="$(printf '\t')" read -r name a mem cpu rdy pid unsched; do
      [ -z "$name" ] && continue
      total=$((total + 1))
      [ "$rdy" = True ] && [ "$unsched" != true ] && ready=$((ready + 1))
      case " $archs " in *" $a "*) ;; *) archs="$archs $a" ;; esac
      [ "$(to_mib "$mem")" -ge 2560 ] && big=$((big + 1))
      [ -z "$prov" ] && prov=${pid%%:*}
    done <<EOF
$outp
EOF
    case $prov in aws) CLOUD=aws; dist=${dist:-EKS or AWS} ;; gce) CLOUD=gcp ;; azure) CLOUD=azure ;; esac
    if [ "$ready" -eq 0 ]; then fail "Nodes" "$total nodes, none Ready and schedulable" "The delegate pod has nowhere to run."
    else pass "Nodes" "$ready of $total Ready, arch:$archs${prov:+, provider $prov}"; fi
    case $archs in *amd64*) NODE_ARCH=amd64 ;; *arm64*) NODE_ARCH=arm64 ;; esac
    case $archs in *[!\ a-z0-9]*|*s390x*|*ppc64le*) warn "Node architecture" "$archs" "The delegate image is amd64 and arm64 only. Pin it to those nodes with a nodeSelector." ;; esac
    if [ "$big" -eq 0 ] && [ "$total" -gt 0 ]; then
      fail "Node memory" "no node has 2.5 GB allocatable" "The delegate requests 2 GB of memory. Add a bigger node pool."
    else pass "Node memory" "$big nodes can fit the delegate's 2 GB request"; fi
  fi

  # Namespace, policies and permissions
  spin_start "Checking namespace $NAMESPACE"
  NS_EXISTS=0
  if k get namespace "$NAMESPACE" >/dev/null 2>&1; then
    NS_EXISTS=1
    local psa; psa=$(k get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
    if [ "$psa" = restricted ]; then
      warn "Namespace $NAMESPACE" "exists; Pod Security is 'restricted'" "The delegate runs as root by default, which 'restricted' blocks. Use 'baseline' for this namespace, or run the delegate as non-root."
    else pass "Namespace $NAMESPACE" "exists${psa:+, Pod Security '$psa'}"; fi
    local np; np=$(k get networkpolicy -n "$NAMESPACE" -o name 2>/dev/null | sed 's#.*/##' | paste -sd ' ' -)
    if [ -n "$np" ]; then
      NETPOLS=$np
      warn "NetworkPolicies" "$np" "Policies in $NAMESPACE can block the delegate's egress (443 to Harness, and DNS on 53). The probe pod below tests it."
    else pass "NetworkPolicies" "none in $NAMESPACE"; fi
    local q; q=$(k get resourcequota,limitrange -n "$NAMESPACE" -o name 2>/dev/null | paste -sd ' ' -)
    [ -n "$q" ] && info "Quotas and limits" "$q (the delegate needs 1 CPU and 2 GB)"
  else
    if [ "$(k auth can-i create namespaces 2>/dev/null)" = yes ]; then
      pass "Namespace $NAMESPACE" "doesn't exist yet; you can create it (helm --create-namespace)"
    else
      fail "Namespace $NAMESPACE" "doesn't exist, and you can't create namespaces" "Ask a cluster admin to create $NAMESPACE, or pick an existing one with -n."
    fi
  fi

  spin_start "Checking your permissions"
  local missing="" r
  for r in deployments.apps secrets configmaps serviceaccounts roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io; do
    [ "$(k auth can-i create "$r" -n "$NAMESPACE" 2>/dev/null)" = yes ] || missing="$missing ${r%%.*}"
  done
  if [ -n "$missing" ]; then
    fail "Install permissions" "can't create:$missing in $NAMESPACE" "Helm needs these to install the delegate. Ask for admin rights on the namespace, or have a cluster admin install it."
  elif [ "$(k auth can-i '*' '*' --all-namespaces 2>/dev/null)" = yes ]; then
    pass "Install permissions" "cluster admin: the default chart (k8sPermissionsType=CLUSTER_ADMIN) installs"
  else
    warn "Install permissions" "you can install in $NAMESPACE, but you aren't cluster admin" \
      "The chart's default binds the delegate to cluster-admin, which you can't grant. Either ask a cluster admin, or install with
--set k8sPermissionsType=NAMESPACE_ADMIN (the delegate can then deploy only to $NAMESPACE) or CLUSTER_VIEWER."
  fi

  if have helm; then
    local hv; hv=$(helm version --template '{{.Version}}' 2>/dev/null)
    case $hv in v3*|v4*) pass "Helm" "$hv" ;; *) warn "Helm" "${hv:-unknown version}" "The delegate chart needs Helm 3." ;; esac
  else
    warn "Helm" "not installed" "Install Helm 3 (https://helm.sh/docs/intro/install/), or apply the delegate's Kubernetes manifest instead."
  fi
  return 0
}

# create_fail OUTPUT NAMESPACE IMAGE: report a probe pod the API server refused to create,
# naming what refused it (Binary Authorization, Gatekeeper, Kyverno, Pod Security, a quota,
# a LimitRange, RBAC, ...) and what to change. Admission rejects the pod before anything
# runs, so the delegate's Deployment would get no pods at all while helm says "deployed".
create_fail() {
  local raw=$1 ns=$2 img=$3 msg l who fix name prefix
  msg=$(printf '%s' "$raw" | tr '\n' ' ' | sed -e 's/^Error from server ([^)]*): //' \
    -e 's/^error when creating "[^"]*": //' -e 's/  */ /g' -e 's/ $//')
  l=$(lower "$msg")
  case $img in */*) prefix=${img%/*}/ ;; *) prefix=$img ;; esac
  case $l in
    *"binary authorization"*|*violates_policy*|*"image policy webhook"*|*imagepolicywebhook*)
      who="Binary Authorization (GKE)"
      fix="The cluster's Binary Authorization policy doesn't allow $img.
Ask its owner to allow the Harness images, e.g. an allowlist pattern ${prefix}*
(gcloud container binauthz policy export shows the policy), or mirror the delegate and upgrader
images to a registry the policy allows and pass --image (Helm: delegateDockerImage, upgrader.upgraderDockerImage)." ;;
    *gatekeeper*)
      name=$(printf '%s' "$msg" | sed -n 's/.*denied the request: \[\([^]]*\)\].*/\1/p')
      who="Gatekeeper${name:+ constraint $name} (Policy Controller on GKE)"
      fix="kubectl get constraints shows it. If it's an allowed-registries rule (K8sAllowedRepos), add $prefix
to its repos or exclude $ns from it; otherwise change what it objects to. Or mirror the delegate and
upgrader images to an allowed registry and pass --image." ;;
    *kyverno*)
      name=$(printf '%s' "$msg" | sed -n 's/.*following polic[a-z]* \([A-Za-z0-9._-]*\).*/\1/p')
      who="Kyverno${name:+ policy $name}"
      fix="kubectl get clusterpolicy,policy -A shows it. Ask its owner for a PolicyException for the delegate in $ns,
or change what it objects to (an image registry rule: mirror the images and pass --image)." ;;
    *"violates podsecurity"*)
      who="Pod Security"
      fix="$ns enforces a Pod Security level the delegate doesn't meet (it runs as root by default).
Label it pod-security.kubernetes.io/enforce=baseline, or run the delegate as non-root." ;;
    *"exceeded quota"*|*"failed quota"*)
      who="a ResourceQuota"
      fix="The quota in $ns has no room for the delegate (1 CPU and 2 GB by default): kubectl describe quota -n $ns.
Raise it, or lower the delegate's cpu and memory in your values." ;;
    *"maximum cpu usage"*|*"maximum memory usage"*|*"minimum cpu usage"*|*"minimum memory usage"*|*"limit to request ratio"*)
      who="a LimitRange"
      fix="The delegate's requests and limits are outside what $ns allows: kubectl describe limitrange -n $ns.
Set cpu and memory in your values within it, or ask for the LimitRange to be widened." ;;
    *"cannot create resource"*)
      who="your Kubernetes permissions"
      fix="Your kubectl user can't create pods in $ns. That's your access, not the delegate's: ask for it, or have
someone who installs the delegate run this." ;;
    *"service account"*"not found"*|*serviceaccount*"not found"*)
      who="a missing service account"
      fix="The pod's service account doesn't exist in $ns. Create it, or let the chart create it (serviceAccount.create)." ;;
    *"admission webhook"*)
      name=$(printf '%s' "$msg" | sed -n 's/.*admission webhook "\([^"]*\)".*/\1/p')
      who="admission webhook ${name:-(unnamed)}"
      fix="kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations shows which tool owns it.
Ask its owner what it objects to." ;;
    *) who="the API server"
       fix="An admission policy (Binary Authorization, Gatekeeper, Kyverno, Pod Security) or a quota may be rejecting it." ;;
  esac
  fail "Probe pod" "rejected by $who: $(printf '%s' "$msg" | cut -c1-300)" "$fix
It would reject the delegate's pods the same way: helm would still say \"deployed\", with no pods."
}

# Build the probe pod from the chart's own Deployment: the pod the delegate will run, with
# sleep in place of the delegate and no health probes. The chart's Secrets, ConfigMaps and
# service account are created under the throwaway release name, and deleted afterwards.
# Returns 0 when the pod is created, 1 on a failure already reported, 2 to use a plain pod.
helm_probe_pod() {
  local ns=$1 name=$2 d=$HELM_DIR dep="$HELM_DIR/Deployment-$HELM_REL.yaml" r miss="" sa labels annots spec ops l outp
  # Secrets and ConfigMaps the values point at, which the chart doesn't create, must already exist
  for r in $(kjp "$dep" '{range .spec.template.spec.volumes[*]}{.secret.secretName}{" "}{end}{range .spec.template.spec.containers[*].env[*]}{.valueFrom.secretKeyRef.name}{" "}{end}'); do
    [ -f "$d/Secret-$r.yaml" ] || k get secret "$r" -n "$ns" >/dev/null 2>&1 || miss="$miss secret/$r"
  done
  for r in $(kjp "$dep" '{range .spec.template.spec.volumes[*]}{.configMap.name}{" "}{end}'); do
    [ -f "$d/ConfigMap-$r.yaml" ] || k get configmap "$r" -n "$ns" >/dev/null 2>&1 || miss="$miss configmap/$r"
  done
  if [ -n "$miss" ]; then
    fail "Helm values" "the delegate pod needs${miss}, which isn't in $ns" \
      "Create it before you install, or the delegate pod never starts. Testing with a plain probe pod instead."
    return 2
  fi
  for r in $(kjp "$dep" '{.spec.template.spec.imagePullSecrets[*].name}'); do
    k get secret "$r" -n "$ns" >/dev/null 2>&1 || warn "Image pull secret" "$r (imagePullSecret) isn't in $ns" "Create it in $ns before you install: kubectl create secret docker-registry $r -n $ns ..."
  done

  # Service account: the chart's own, copied under the probe's name, or an existing one
  sa=$(kjp "$dep" '{.spec.template.spec.serviceAccountName}'); sa=${sa:-default}
  if [ "$sa" != "$HELM_REL" ] && ! k get serviceaccount "$sa" -n "$ns" >/dev/null 2>&1; then
    if [ -f "$d/ServiceAccount-$sa.yaml" ]; then
      sed "s/^  name: $sa\$/  name: $HELM_REL/" "$d/ServiceAccount-$sa.yaml" > "$d/ServiceAccount-$HELM_REL.yaml"
      sa=$HELM_REL
    else
      fail "Service account" "$sa isn't in $ns, and your values don't create it (serviceAccount.create: false)" \
        "Create it first, or Kubernetes won't create the delegate pod. The probe uses the default service account."
      sa=default
    fi
  fi
  : > "$d/res.yaml"
  for r in "$d"/Secret-"$HELM_REL"*.yaml "$d"/ConfigMap-"$HELM_REL"*.yaml "$d"/ServiceAccount-"$HELM_REL".yaml; do
    [ -f "$r" ] && { printf -- '---\n'; cat "$r"; } >> "$d/res.yaml"
  done

  labels=$(kjp "$dep" '{.spec.template.metadata.labels}'); [ -n "$labels" ] || labels='{}'
  annots=$(kjp "$dep" '{.spec.template.metadata.annotations}'); [ -n "$annots" ] || annots='{}'
  spec=$(kjp "$dep" '{.spec.template.spec}')
  printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"%s","labels":%s,"annotations":%s},"spec":%s}\n' \
    "$name" "$labels" "$annots" "$spec" > "$d/pod0.json"
  ops='{"op":"add","path":"/spec/restartPolicy","value":"Never"},{"op":"add","path":"/spec/terminationGracePeriodSeconds","value":0}'
  ops="$ops"',{"op":"add","path":"/spec/containers/0/command","value":["sleep","900"]},{"op":"add","path":"/spec/containers/0/args","value":[]}'
  for r in startupProbe livenessProbe readinessProbe; do ops="$ops,{\"op\":\"add\",\"path\":\"/spec/containers/0/$r\",\"value\":null}"; done
  ops="$ops"',{"op":"add","path":"/metadata/labels/app.kubernetes.io~1component","value":"harness-delegate-preflight"}'
  ops="$ops,{\"op\":\"add\",\"path\":\"/spec/serviceAccountName\",\"value\":\"$sa\"}"
  [ "$IMAGE_CLI" = 1 ] && ops="$ops,{\"op\":\"add\",\"path\":\"/spec/containers/0/image\",\"value\":\"$IMAGE\"}"
  for l in $POD_LABELS; do
    ops="$ops,{\"op\":\"add\",\"path\":\"/metadata/labels/$(printf '%s' "${l%%=*}" | sed 's/~/~0/g; s#/#~1#g')\",\"value\":\"${l#*=}\"}"
  done
  if ! KUBECONFIG=/dev/null kubectl patch --local -f "$d/pod0.json" --type json -p "[$ops]" -o json > "$d/pod.json" 2> "$d/patch.err"; then
    fail "Probe pod" "couldn't build it from the chart: $(tail -1 "$d/patch.err" | cut -c1-160)" "Testing with a plain probe pod instead."
    return 2
  fi

  if [ -s "$d/res.yaml" ]; then
    HELM_RES_NS=$ns
    if ! outp=$(k create -n "$ns" -f "$d/res.yaml" 2>&1); then
      fail "Probe pod" "couldn't create the chart's Secrets and ConfigMaps: $(printf '%s' "$outp" | tail -1 | cut -c1-160)" \
        "Helm creates the same objects, so check your rights in $ns."
      return 1
    fi
  fi
  if ! outp=$(k create -n "$ns" -f "$d/pod.json" 2>&1); then
    create_fail "$outp" "$ns" "$(kjp "$d/pod.json" '{.spec.containers[0].image}')"
    return 1
  fi
  POD_CONTAINER=$(kjp "$d/pod.json" '{.spec.containers[0].name}')
  local req; req=$(kjp "$d/pod.json" '{.spec.containers[0].resources.requests.cpu} CPU, {.spec.containers[0].resources.requests.memory}')
  info "Probe pod" "$ns/$name: the delegate pod from your values (image $(kjp "$d/pod.json" '{.spec.containers[0].image}'), requests ${req}; deleted when done)"
  return 0
}

# Run the network checks again from a pod in the cluster: nodes and pods often take a
# different path out (NAT, NetworkPolicies, node proxies), and nodes pull the image themselves.
section_in_cluster() {
  section "From inside the cluster"
  local script=${BASH_SOURCE[0]:-$0}
  if [ ! -f "$script" ] || ! grep -q HDPF_SCRIPT_MARKER "$script" 2>/dev/null; then
    skip "Probe pod" "save this script to a file and run it from there to test from inside the cluster"
    return
  fi
  local ns=$NAMESPACE
  if [ "${NS_EXISTS:-0}" != 1 ]; then
    ns=default
    info "Probe namespace" "$NAMESPACE doesn't exist yet, so the probe runs in 'default' (policies scoped to $NAMESPACE aren't tested)"
  fi
  local name="harness-delegate-preflight-$PROBE_ID" hp=2
  POD_CONTAINER=$name
  if [ "$HELM_MODE" = 1 ]; then
    helm_probe_pod "$ns" "$name"; hp=$?
    [ "$hp" = 1 ] && return
  fi
  local labels="app.kubernetes.io/name=harness-delegate-preflight" l
  for l in $POD_LABELS; do labels="$labels,$l"; done
  local ips=""; [ -n "$IMAGE_PULL_SECRET" ] && ips=",\"imagePullSecrets\":[{\"name\":\"$IMAGE_PULL_SECRET\"}]"
  local overrides="{\"apiVersion\":\"v1\",\"spec\":{\"terminationGracePeriodSeconds\":0,\"automountServiceAccountToken\":false${ips},\"containers\":[{\"name\":\"$name\",\"image\":\"$IMAGE\",\"command\":[\"sleep\",\"900\"],\"resources\":{\"requests\":{\"cpu\":\"50m\",\"memory\":\"128Mi\"},\"limits\":{\"memory\":\"512Mi\"}}}]}}"
  local outp
  if [ "$hp" != 0 ]; then
    info "Probe pod" "$ns/$name, image $IMAGE (deleted when done)"
    if ! outp=$(k run "$name" -n "$ns" --image="$IMAGE" --restart=Never --labels="$labels" --overrides="$overrides" 2>&1); then
      create_fail "$outp" "$ns" "$IMAGE"
      return
    fi
  fi
  POD=$name; NAMESPACE_SAVED=$NAMESPACE; NAMESPACE=$ns   # cleanup() deletes $POD in $NAMESPACE
  local t0 now st phase reason msg sreason smsg ready waited
  t0=$(date +%s)
  while :; do
    now=$(date +%s); waited=$((now - t0))
    st=$(k get pod "$POD" -n "$ns" -o jsonpath='{.status.phase}|{.status.containerStatuses[0].state.waiting.reason}|{.status.containerStatuses[0].state.waiting.message}|{.status.conditions[?(@.type=="PodScheduled")].reason}|{.status.conditions[?(@.type=="PodScheduled")].message}|{.status.containerStatuses[0].ready}' 2>/dev/null)
    IFS='|' read -r phase reason msg sreason smsg ready <<EOF
$st
EOF
    if [ "$phase" = Running ] && [ "$ready" = true ]; then break; fi
    case $reason in
      ErrImagePull|ImagePullBackOff|InvalidImageName|ErrImageNeverPull|RegistryUnavailable)
        local ev reg why fix
        ev=$(k get events -n "$ns" --field-selector "involvedObject.name=$POD,reason=Failed" -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -v '^Error: ' | tail -1)
        [ -n "$ev" ] && msg=$ev
        reg=$(parse_image "$IMAGE"; printf '%s' "$IMG_REG")
        case $(lower "$msg") in
          *"not found"*|*"manifest unknown"*|*"name unknown"*|*"does not exist"*)
            why="the node says the image doesn't exist"
            fix="Check the image name and tag: $IMAGE" ;;
          *unauthorized*|*denied*|*forbidden*|*"authentication required"*|*" 401"*|*" 403"*)
            why="the registry refused the node's pull (auth)"
            fix="Create a pull secret for $reg in $ns and pass it: --image-pull-secret <name> (Helm: imagePullSecret)." ;;
          *"x509"*|*certificate*)
            why="the node doesn't trust the registry's TLS certificate"
            fix="TLS inspection on the nodes' path to $reg. Add the inspecting CA to the nodes' container runtime
(containerd: /etc/containerd/certs.d/$reg/), or exempt $reg from inspection." ;;
          *"i/o timeout"*|*"timeout"*|*"connection refused"*|*"no route"*|*"dial tcp"*|*"no such host"*|*"connection reset"*|*eof*)
            why="the node can't reach $reg"
            if [ "${REG_OK:-0}" = 1 ]; then
              fix="This machine reaches $reg, but the nodes pull images over their own network path (node egress
or NAT, a containerd proxy, a registry mirror). Allow the nodes to reach $reg and its layer host,
or mirror the image to a registry they can reach and pass --image (and --image-pull-secret)."
            else
              fix="Neither this machine nor the nodes can reach $reg. Allow it, or mirror the image to a registry
the nodes can reach and pass --image (and --image-pull-secret)."
            fi ;;
          *) why="the node couldn't pull the image"
             fix="kubectl describe pod $POD -n $ns shows the node's error." ;;
        esac
        fail "Image pull on the node" "$why" "$(printf '%s' "$msg" | sed 's/^Failed to pull image "[^"]*": //' | cut -c1-200)
$fix"
        return ;;
      CreateContainerConfigError|CreateContainerError|RunContainerError)
        fail "Probe pod" "$reason: $(printf '%s' "$msg" | cut -c1-160)" ""; return ;;
    esac
    if [ "$sreason" = Unschedulable ] && [ "$waited" -gt 20 ]; then
      fail "Probe pod" "can't be scheduled: $(printf '%s' "$smsg" | cut -c1-200)" "The delegate (1 CPU, 2 GB) won't schedule either. Check node capacity, taints and quotas."
      return
    fi
    case $phase in Failed|Succeeded) fail "Probe pod" "exited ($phase) before the checks ran" "The image needs bash and sleep."; return ;; esac
    if [ "$waited" -ge "$POD_TIMEOUT" ]; then
      fail "Probe pod" "not running after ${POD_TIMEOUT}s (${phase:-Pending}${reason:+, $reason})" "Check: kubectl describe pod $POD -n $ns"; return
    fi
    if [ "$IS_TTY" = 1 ]; then spin_start "Starting the probe pod: ${reason:-${phase:-Pending}} (${waited}s; pulling a 1 GB image can take a few minutes)"; fi
    sleep 2
  done
  local pulled; pulled=$(k get events -n "$ns" --field-selector "involvedObject.name=$POD" -o jsonpath='{range .items[?(@.reason=="Pulled")]}{.message}{"\n"}{end}' 2>/dev/null | tail -1)
  local pt psz
  pt=$(printf '%s' "$pulled" | sed -n 's/.* in \([0-9.]*[a-z]*\) (.*/\1/p')
  psz=$(printf '%s' "$pulled" | sed -n 's/.*Image size: \([0-9]*\) bytes.*/\1/p')
  if [ -n "$pt" ]; then pass "Image pull on the node" "pulled in $pt${psz:+ ($(human_bytes "$psz") unpacked)}"
  else pass "Image pull on the node" "image was already on the node (pod started in $(( $(date +%s) - t0 ))s)"; fi

  # Stream this script into the pod and run the network checks there
  local fwd="" a
  # The Helm pod has the delegate's own proxy settings, so this machine's aren't passed in
  [ "$hp" != 0 ] && [ -n "$PROXY_URL" ] && fwd="HDPF_FWD_PROXY=$(printf '%q' "$PROXY_URL")"
  [ "$hp" != 0 ] && [ -n "$NOPROXY_LIST" ] && fwd="$fwd
HDPF_FWD_NOPROXY=$(printf '%q' "$NOPROXY_LIST")"
  local args="--in-pod --color $COLOR --symbols $SYMBOLS --timeout $T --url $MGR_BASE"
  [ -n "$ACCOUNT_ID" ] && args="$args --account-id $ACCOUNT_ID"
  [ "$DIRECT_ONLY" = 1 ] && args="$args --direct"
  [ "$VERBOSE" = 1 ] && args="$args --verbose"
  for a in $EXTRA_CHECKS; do args="$args --check $a"; done
  : > "$WORK/pod-records"
  spin_start "Running the checks in the pod"
  # shellcheck disable=SC2086
  { printf '%s\n' "$fwd"; cat "$script"; } | "${KUBECTL[@]}" exec -i -n "$ns" "$POD" -c "$POD_CONTAINER" -- bash -s -- $args 2>&1 | {
    first=1
    while IFS= read -r line; do
      [ "$first" = 1 ] && { spin_stop; first=0; }
      case $line in
        '##HDPF|'*) printf '%s\n' "$line" >> "$WORK/pod-records" ;;
        *) out "$line" ;;
      esac
    done
  }
  # Fold the pod's results into ours
  pod_flags() {
    case $label in WebSocket) WS_FAILED=1 ;; "TLS certificate") INTERCEPT_SEEN=1 ;; esac
    case $msg2 in *"certificate not trusted"*) INTERCEPT_SEEN=1 ;; esac
    # Only the network checks say anything about the cluster's egress
    if [ "$kind" = fail ]; then
      case $label in
        *"via proxy"*) POD_NET_FAILED=1; POD_PROXY_FAILED=1 ;;
        "Resolve "*|"HTTPS to "*|"Log service") POD_NET_FAILED=1 ;;
      esac
    fi
  }
  local kind label msg2 hnt
  while IFS='|' read -r _ kind label msg2 hnt; do
    case $kind in
      pass) N_PASS=$((N_PASS + 1)) ;;
      warn) N_WARN=$((N_WARN + 1)); pod_flags; record warn "[pod] $label" "$msg2" "$(printf '%s' "$hnt" | tr '\037' '\n')" ;;
      fail) N_FAIL=$((N_FAIL + 1)); POD_FAILED=1; pod_flags; record fail "[pod] $label" "$msg2" "$(printf '%s' "$hnt" | tr '\037' '\n')" ;;
      DONE) POD_DONE=1 ;;
    esac
  done < "$WORK/pod-records"
  if [ "${POD_DONE:-0}" != 1 ]; then
    fail "Probe pod" "the checks in the pod didn't finish" "Run with --verbose, or check: kubectl logs $POD -n $ns"
  fi
  if [ "${POD_NET_FAILED:-0}" = 1 ] && [ "${MGR_OK:-0}" = 1 ]; then
    local dn=${HV_NAME:-<delegate-name>}
    out ""
    if [ "${POD_PROXY_FAILED:-0}" = 1 ] && [ "$hp" = 0 ] && [ -n "$HV_PROXY" ]; then
      out "  ${C_YEL}${S_WARN}${C_R} ${C_B}The proxy in your values doesn't get pods out of the cluster.${C_R}"
      hint "The delegate pod goes through $HV_PROXY (proxyHost, proxyPort, proxyScheme). Check that pods can
reach it on that port (a NetworkPolicy or the nodes' firewall), and that it allows the hosts above.
If pods should go out directly instead, take the proxy out of your values and rerun."
    else
      out "  ${C_YEL}${S_WARN}${C_R} ${C_B}This machine reaches Harness, but pods in the cluster can't.${C_R}"
      if [ -n "${NETPOLS:-}" ]; then
        local retest="To test with the probe pod first, rerun with --pod-label harness.io/name=$dn.
"
        [ "$hp" = 0 ] && retest=""   # the probe already had the delegate's labels
        hint "The NetworkPolicies in $ns ($NETPOLS) are the likely cause. Allow the delegate's pods out on 443:
  kubectl apply -n $ns -f - <<'YAML'
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata: {name: harness-delegate-egress}
  spec:
    podSelector: {matchLabels: {harness.io/name: $dn}}
    policyTypes: [Egress]
    egress: [{ports: [{port: 443, protocol: TCP}, {port: 53, protocol: UDP}, {port: 53, protocol: TCP}]}]
  YAML
${retest}If it still fails, look at the nodes' egress too. $(cloud_hint 443)"
      else
        hint "Pods leave the cluster through the nodes' network: NAT gateway, firewall, egress rules, or a
node-level proxy that this machine doesn't use. $(cloud_hint 443)"
      fi
    fi
  fi
  "${KUBECTL[@]}" delete pod "$POD" -n "$ns" --grace-period=0 --wait=false >/dev/null 2>&1
  if [ -n "$HELM_RES_NS" ]; then
    "${KUBECTL[@]}" delete -n "$HELM_RES_NS" -f "$HELM_DIR/res.yaml" --ignore-not-found --wait=false >/dev/null 2>&1
    HELM_RES_NS=""
  fi
  POD=""; NAMESPACE=${NAMESPACE_SAVED:-$NAMESPACE}
}

# ---------------------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------------------
can_prompt() { [ "$INTERACTIVE" != 0 ] && [ "$IS_TTY" = 1 ] && ( : </dev/tty ) 2>/dev/null; }
ask() {   # ask PROMPT DEFAULT -> REPLY
  printf '%s' "$1" >/dev/tty
  IFS= read -r REPLY </dev/tty || REPLY=""
  [ -z "$REPLY" ] && REPLY=$2
}

if ! have curl; then echo "harness-delegate-preflight needs curl. Install it, then run this again." >&2; exit 1; fi

if [ "$IN_POD" = 0 ]; then
  if [ "$NO_REPORT" = 0 ]; then
    [ -n "$REPORT" ] || REPORT="./harness-delegate-preflight-$(date +%Y%m%d-%H%M%S).txt"
    if ! { exec 3>"$REPORT"; } 2>/dev/null; then REPORT="${TMPDIR:-/tmp}/$(basename "$REPORT")"; exec 3>"$REPORT"; fi
    REPORT_OPEN=1
  fi
  out ""
  out "  ${C_B}${C_MAG}Harness Delegate preflight${C_R} ${C_D}v$VERSION${C_R}"
  out "  ${C_D}Checks what a delegate needs on this network, and says what to fix.${C_R}"
  rep "  Run: $(date -u '+%Y-%m-%d %H:%M:%S UTC') by $(id -un 2>/dev/null)@$(hostname 2>/dev/null)"
  rep "  Args: url=${URL:-} account=${ACCOUNT_ID:-} target=$TARGET namespace=$NAMESPACE"
fi

# Where's the account?
if [ -z "$URL" ] && [ -z "$ACCOUNT_ID" ] && [ "$HELM_MODE" = 0 ] && can_prompt; then
  out ""
  ask "  Paste your Harness URL (your browser's address bar is fine) or your account ID
  [https://app.harness.io]: " "https://app.harness.io"
  case $REPLY in *.*|*/*) URL=$REPLY ;; *) ACCOUNT_ID=$REPLY ;; esac
fi

# Where will the delegate run?
if [ "$TARGET" = auto ] && [ "$IN_POD" = 0 ]; then
  if can_prompt; then
    def=2; have kubectl && ! have docker && def=1
    ctxname=""; have kubectl && ctxname=$(kubectl config current-context 2>/dev/null)
    out ""
    out "  Where will the delegate run?"
    out "    1) A Kubernetes cluster${ctxname:+ (kubectl context: $ctxname)}"
    out "    2) This machine, with Docker (a VM in the cloud or on-prem)"
    out "    3) Just check the network"
    ask "  Choose 1, 2 or 3 [$def]: " "$def"
    case $REPLY in 1) TARGET=k8s ;; 3) TARGET=network ;; *) TARGET=docker ;; esac
  elif have docker || have podman; then TARGET=docker
  else TARGET=network; fi
fi
[ "$IN_POD" = 1 ] && TARGET=network
[ "$IN_CLUSTER" = auto ] && IN_CLUSTER=1
rep "  Target: $TARGET"

section_environment
[ "$HELM_MODE" = 1 ] && section_helm_values
section_proxy

# Work out the manager URL: from --url, or by finding the account's cluster
URL_GAVE_ACCOUNT=0
[ "$IN_POD" = 0 ] && section "Harness account"
if [ -n "$URL" ]; then
  parse_manager_url "$URL"
  [ "$URL_GAVE_ACCOUNT" = 1 ] && info "Account ID" "$ACCOUNT_ID (from the URL)"
  [ "$IN_POD" = 0 ] && info "Harness URL" "$MGR_BASE"
  # The browser shows app.harness.io for accounts on several clusters, but the delegate has
  # to use the account's own cluster. If the account isn't here, find it and test that one.
  if [ -n "$ACCOUNT_ID" ] && [ "$IN_POD" = 0 ]; then
    spin_start "Checking that account $ACCOUNT_ID is on $MGR_BASE"
    http_probe "$(path_for "$MGR_HOST")" "$MGR_BASE/api/account/$ACCOUNT_ID/status"
    if grep -q ACCOUNT_DOES_NOT_EXIST "$WORK/body"; then
      spin_start "Looking for account $ACCOUNT_ID on the other Harness clusters"
      if discover_cluster && [ "$FOUND_BASE" != "$MGR_BASE" ] && [ "$HELM_MODE" = 1 ]; then
        HV_FIX="${HV_FIX}managerEndpoint: $FOUND_BASE
"
        fail "managerEndpoint" "account $ACCOUNT_ID isn't on $MGR_BASE (from your values, or the chart's default); it's on $FOUND_BASE" \
          "The delegate would never register. Set managerEndpoint: $FOUND_BASE in your values. Testing $FOUND_BASE."
        parse_manager_url "$FOUND_BASE"
      elif [ "$FOUND_BASE" != "$MGR_BASE" ] && [ -n "$FOUND_BASE" ]; then
        warn "Harness cluster" "account $ACCOUNT_ID is on $FOUND_BASE, not $MGR_BASE; testing $FOUND_BASE" \
          "The delegate must use the account's own cluster: MANAGER_HOST_AND_PORT=$FOUND_BASE (Helm: managerEndpoint).
The install command from Harness (Project Settings > Delegates > New Delegate) has it right."
        parse_manager_url "$FOUND_BASE"
      fi
    fi
  fi
elif [ -n "$ACCOUNT_ID" ]; then
  spin_start "Finding which Harness cluster account $ACCOUNT_ID is on"
  if discover_cluster; then
    parse_manager_url "$FOUND_BASE"
    pass "Harness cluster" "account $ACCOUNT_ID is on $FOUND_BASE"
  else
    parse_manager_url "https://app.harness.io"
    info "Harness cluster" "couldn't find account $ACCOUNT_ID yet; testing app.harness.io"
  fi
else
  parse_manager_url "https://app.harness.io"
  info "Harness URL" "$MGR_BASE (pass --url or --account-id to test yours)"
fi
case $MGR_HOST in *.harness.io) ;; *) info "Manager" "$MGR_HOST isn't a harness.io host: treating it as a self-managed platform" ;; esac

section_dns
section_manager
K8S_OK=0
if [ "$TARGET" = k8s ]; then section_k8s && K8S_OK=1; fi   # first, so the image check uses the nodes' arch
[ "$IN_POD" = 0 ] && section_registry
section_extra
if [ "$TARGET" = docker ]; then section_docker; section_resources; fi
if [ "$K8S_OK" = 1 ] && [ "$IN_CLUSTER" = 1 ]; then section_in_cluster; fi

# ---------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------
if [ "$IN_POD" = 1 ]; then
  printf '##HDPF|DONE|||\n'
  exit 0
fi

section "Summary"
out "  ${C_GRN}${S_PASS} $N_PASS passed${C_R}   ${C_YEL}${S_WARN} $N_WARN warnings${C_R}   ${C_RED}${S_FAIL} $N_FAIL failed${C_R}"
i=0
if [ "$N_FAIL" -gt 0 ]; then
  out ""; out "  ${C_B}Fix these first:${C_R}"
  while [ $i -lt ${#REC_KIND[@]} ]; do
    if [ "${REC_KIND[$i]}" = fail ]; then
      out "  ${C_RED}${S_FAIL}${C_R} ${C_B}${REC_LABEL[$i]}${C_R}: ${REC_MSG[$i]}"
    fi
    i=$((i + 1))
  done
fi
i=0
if [ "$N_WARN" -gt 0 ]; then
  out ""; out "  ${C_B}Worth a look:${C_R}"
  while [ $i -lt ${#REC_KIND[@]} ]; do
    [ "${REC_KIND[$i]}" = warn ] && out "  ${C_YEL}${S_WARN}${C_R} ${REC_LABEL[$i]}: ${REC_MSG[$i]}"
    i=$((i + 1))
  done
fi

# What to put in the delegate's configuration
mgr=${WRONG_CLUSTER:-$MGR_BASE}
out ""
out "  ${C_B}Delegate settings for this network${C_R}"
if [ "$TARGET" = k8s ] && [ "$HELM_MODE" = 1 ]; then
  [ "${WS_FAILED:-0}" = 1 ] && [ "$HV_POLL" != true ] && HV_FIX="${HV_FIX}pollForTasks: \"true\"
"
  [ -n "$INTERCEPT_SEEN" ] && [ -z "$HV_CA" ] && HV_FIX="${HV_FIX}delegateCustomCa: {secretName: harness-delegate-ca}   # a secret with your proxy's root CA
"
  if [ -z "$HV_PROXY" ] && [ -n "$PROXY_URL" ] && [ "${DIRECT_OK:-0}" != 1 ]; then
    HV_FIX="${HV_FIX}proxyHost: $PX_HOST
proxyPort: $PX_PORT
proxyScheme: $(printf '%s' "$PX_SCHEME" | tr '[:lower:]' '[:upper:]')
noProxy: ${NOPROXY_LIST:-<internal hosts, comma-separated>}
"
    [ -n "$PX_USER" ] && HV_FIX="${HV_FIX}proxyUser: <base64 user>
proxyPassword: <base64 password>
"
  fi
  fl=""; for f in "${HELM_VALUES[@]}"; do fl="$fl -f $f"; done
  [ "${#HELM_SETS[@]}" -gt 0 ] && fl="$fl <your --set values>"
  if [ -n "$HV_FIX" ]; then
    out "    Add to your values:"
    printf '%s' "$HV_FIX" | while IFS= read -r l; do out "      $l"; done
  elif [ "$N_FAIL" = 0 ]; then
    out "    Your values work on this network as they are."
  fi
  [ -z "$HV_CA" ] && [ -n "$INTERCEPT_SEEN" ] && out "      ${C_D}kubectl create secret generic harness-delegate-ca -n $NAMESPACE --from-file=ca.crt=<root CA, PEM>${C_R}"
  out "    ${C_D}helm upgrade --install <name> harness-delegate/harness-delegate-ng -n $NAMESPACE --create-namespace${fl} \\${C_R}"
  out "    ${C_D}  --set delegateToken=<from Harness>${C_R}"
elif [ "$TARGET" = k8s ]; then
  out "    ${C_D}helm repo add harness-delegate $HELM_REPO_URL${C_R}"
  out "    ${C_D}helm upgrade --install <name> harness-delegate/harness-delegate-ng -n $NAMESPACE --create-namespace \\${C_R}"
  out "      --set managerEndpoint=$mgr \\"
  [ -n "$ACCOUNT_ID" ] && out "      --set accountId=$ACCOUNT_ID \\"
  out "      --set delegateDockerImage=${ALT_IMAGE:-${IMAGE:-$DEFAULT_GAR_REPO:$FALLBACK_TAG}} \\"
  if [ -n "$PROXY_URL" ] && [ "${DIRECT_OK:-0}" != 1 ]; then
    out "      --set proxyHost=$PX_HOST --set proxyPort=$PX_PORT --set proxyScheme=$(printf '%s' "$PX_SCHEME" | tr '[:lower:]' '[:upper:]') \\"
    [ -n "$PX_USER" ] && out "      --set proxyUser=<base64 user> --set proxyPassword=<base64 password> \\"
    out "      --set noProxy=${NOPROXY_LIST:-<internal hosts, comma-separated>} \\"
  fi
  [ "${WS_FAILED:-0}" = 1 ] && out "      --set pollForTasks=true \\"
  [ -n "$INTERCEPT_SEEN" ] && out "      --set delegateCustomCa.secretName=harness-delegate-ca \\"
  out "      --set delegateToken=<from Harness> --set delegateName=<name>"
else
  out "    MANAGER_HOST_AND_PORT=$mgr"
  out "    LOG_STREAMING_SERVICE_URL=$mgr/log-service/"
  [ -n "$ACCOUNT_ID" ] && out "    ACCOUNT_ID=$ACCOUNT_ID"
  out "    image: ${ALT_IMAGE:-${IMAGE:-$DEFAULT_GAR_REPO:$FALLBACK_TAG}}"
  if [ -n "$PROXY_URL" ] && [ "${DIRECT_OK:-0}" != 1 ]; then
    out "    PROXY_HOST=$PX_HOST  PROXY_PORT=$PX_PORT  PROXY_SCHEME=$(printf '%s' "$PX_SCHEME" | tr '[:lower:]' '[:upper:]')"
    [ -n "$PX_USER" ] && out "    PROXY_USER=$PX_USER  PROXY_PASSWORD=<password>"
    out "    NO_PROXY=${NOPROXY_LIST:-<internal hosts, comma-separated>}"
  fi
  [ "${WS_FAILED:-0}" = 1 ] && out "    POLL_FOR_TASKS=true"
  [ -n "$INTERCEPT_SEEN" ] && out "    custom CA: mount your proxy's root CA (PEM) at /opt/harness-delegate/ca-bundle/"
fi

if [ -n "${REPORT_OPEN:-}" ]; then
  # The report gets every hint in full
  rep ""; rep "  Details"
  i=0
  while [ $i -lt ${#REC_KIND[@]} ]; do
    rep "  [$(printf '%s' "${REC_KIND[$i]}" | tr '[:lower:]' '[:upper:]')] ${REC_LABEL[$i]}: ${REC_MSG[$i]}"
    [ -n "${REC_HINT[$i]}" ] && printf '%s\n' "${REC_HINT[$i]}" | sed 's/^/      /' >&3
    i=$((i + 1))
  done
  exec 3>&-
  REPORT_OPEN=""
  printf '\n  %sReport saved to %s. Send it to Harness Support if you need help.%s\n\n' "$C_D" "$REPORT" "$C_R"
else
  printf '\n'
fi
[ "$N_FAIL" -gt 0 ] && exit 1
exit 0
