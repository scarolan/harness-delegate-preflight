#!/usr/bin/env bash
# Run the preflight's Helm mode (-f values.yaml) against a disposable Kubernetes cluster in
# the ways a customer's values and cluster go wrong, and check the diagnosis.
#
# Needs: kubectl, helm, openssl, and a cluster that enforces NetworkPolicies (k3s, Rancher
# Desktop and Calico do; kind's default CNI doesn't).
#
#   export ACCOUNT=<account ID> URL=<its Harness URL, e.g. https://app.harness.io>
#   tests/k8s-scenarios.sh                        # every scenario, current context
#   CONTEXT=rancher-desktop tests/k8s-scenarios.sh netpol ca
#
# It creates the namespace $NS (hdpf-test), and deletes it at the end.

HERE=$(cd "$(dirname "$0")/.." && pwd)
S="$HERE/harness-delegate-preflight.sh"
ACCOUNT=${ACCOUNT:?set ACCOUNT to a Harness account ID to test against}
URL=${URL:?set URL to the Harness URL of that account, e.g. https://app.harness.io}
NS=${NS:-hdpf-test}
OUT=${OUT:-/tmp/hdpf-k8s}
CONTEXT=${CONTEXT:-$(kubectl config current-context)}
K=(kubectl --context "$CONTEXT")
mkdir -p "$OUT"
PASSED=0; FAILED=0; FAILED_NAMES=""

say() { printf '\n\033[1;35m=== %s\033[0m\n' "$*"; }

# values FILE [extra yaml lines...]: the base values plus extras
values() {
  local f="$OUT/$1.yaml"; shift
  { printf 'accountId: %s\nmanagerEndpoint: %s\ndelegateName: preflight-test\n' "$ACCOUNT" "$URL"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"
  printf '%s' "$f"
}

# run NAME EXPECT_RC "grep pattern" ... -- preflight args...
run() {
  local name=$1 want=$2; shift 2
  local pats=() a
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do pats+=("$1"); shift; done
  shift
  say "$name"
  "$S" -n "$NS" --context "$CONTEXT" --no-report --timeout 5 "$@" > "$OUT/$name.txt" 2>&1
  local rc=$? ok=1 missing=""
  [ "$rc" = "$want" ] || { ok=0; missing="exit $rc (wanted $want)"; }
  for a in "${pats[@]}"; do grep -qE -- "$a" "$OUT/$name.txt" || { ok=0; missing="$missing | missing: $a"; }; done
  sed -n '/^── \(Helm values\|From inside\|Pod: Harness manager\|Summary\)/,/^$/p' "$OUT/$name.txt" | grep -E '✖|⚠|↳|✔|ℹ|^    [a-zA-Z]|^      [a-zA-Z]' | head -24
  # Nothing of ours may be left behind (the probe pod is deleted without waiting, so skip pods)
  sleep 2
  local left; left=$("${K[@]}" get secret,cm,sa -n "$NS" -o name 2>/dev/null | grep -E '/hdpf-')
  [ -z "$left" ] || { ok=0; missing="$missing | left behind: $(printf '%s' "$left" | tr '\n' ' ')"; }
  if [ "$ok" = 1 ]; then printf '\033[32mSCENARIO PASSED\033[0m %s\n' "$name"; PASSED=$((PASSED+1))
  else printf '\033[31mSCENARIO FAILED\033[0m %s: %s\n' "$name" "$missing"; FAILED=$((FAILED+1)); FAILED_NAMES="$FAILED_NAMES $name"; fi
}

# ------------------------------------------------------------------------------------------
sc_baseline() {
  run baseline 0 'Chart +harness-delegate-ng-.* renders' 'the delegate pod from your values' \
    'Pod: Harness manager' 'Your values work on this network as they are' -- -f "$(values baseline)"
}

sc_values() {   # mistakes in the values themselves
  run no_account 1 'accountId +not in your values' 'Add to your values:' '^      accountId: ' \
    -- -f "$(values no_account)" --set accountId=null
  run set_override 0 'Proxy +none \(proxyHost\)' -- -f "$(values set_override 'proxyHost: proxy.invalid' 'proxyPort: "3128"')" --set proxyHost=
  # The chart defaults managerEndpoint to app.harness.io, which is only wrong for other clusters
  if [ "${URL%/}" = https://app.harness.io ]; then
    say "default_manager: skipped (the account is on app.harness.io, the chart's default)"; return
  fi
  printf 'accountId: %s\ndelegateName: preflight-test\n' "$ACCOUNT" > "$OUT/default_mgr.yaml"
  run default_manager 1 "managerEndpoint +account .* isn't on https://app.harness.io" '^      managerEndpoint: https://' \
    -- -f "$OUT/default_mgr.yaml"
}

sc_proxy() {   # a proxy in the values that pods can't use
  run bad_proxy 1 'from PROXY_HOST' "The proxy in your values doesn't get pods out" \
    -- -f "$(values bad_proxy 'proxyHost: 10.255.255.1' 'proxyPort: "3128"' 'proxyScheme: http')"
}

sc_ca() {   # delegateCustomCa: a missing secret, then a real one
  run ca_missing 1 'needs secret/no-such-ca' 'Testing with a plain probe pod' \
    -- -f "$(values ca_missing 'delegateCustomCa:' '  secretName: no-such-ca')"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/ca.key" -out "$OUT/ca.pem" -days 2 -subj /CN=hdpf-test-ca >/dev/null 2>&1
  "${K[@]}" -n "$NS" create secret generic test-ca --from-file=ca.pem="$OUT/ca.pem" >/dev/null
  run ca_loaded 0 'Custom CA +.*1 certificate|Custom CA +.*ca-bundle' 'the delegate pod from your values' \
    -- -f "$(values ca_loaded 'delegateCustomCa:' '  secretName: test-ca')"
  "${K[@]}" -n "$NS" delete secret test-ca >/dev/null
}

sc_netpol() {   # egress only for the delegate's labels: the values' pod gets out, others don't
  "${K[@]}" -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-egress}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress: [{ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]}]
EOF
  run netpol_deny 1 "pods in the cluster can't" 'harness.io/name: preflight-test' -- -f "$(values netpol_deny)"
  "${K[@]}" -n "$NS" apply -f - >/dev/null <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-delegate}
spec:
  podSelector: {matchLabels: {harness.io/name: preflight-test}}
  policyTypes: [Egress]
  egress: [{ports: [{port: 443, protocol: TCP}]}]
EOF
  run netpol_allow 0 'Pod: Harness manager' 'HTTPS to .* healthy' -- -f "$(values netpol_allow)"
  "${K[@]}" -n "$NS" delete netpol --all >/dev/null
}

ALL="baseline values proxy ca netpol"
"${K[@]}" create namespace "$NS" >/dev/null 2>&1
trap '"${K[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1' EXIT INT TERM
for s in ${*:-$ALL}; do "sc_$s"; done
printf '\n%s passed, %s failed%s\n' "$PASSED" "$FAILED" "${FAILED_NAMES:+:$FAILED_NAMES}"
[ "$FAILED" = 0 ]
