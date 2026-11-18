#!/usr/bin/env bash
# Check how the preflight explains a probe pod the API server refuses to create, without a
# cluster: feed create_fail() the errors each admission controller returns and check what it
# names and suggests. Covers the ones that are hard to stand up locally (Binary Authorization
# needs GKE). tests/k8s-scenarios.sh admission runs the quota case against a real cluster.
#
#   tests/create-fail.sh

HERE=$(cd "$(dirname "$0")/.." && pwd)
S="$HERE/harness-delegate-preflight.sh"
IMG=us-docker.pkg.dev/gar-prod-setup/harness-public/harness/delegate:26.10.90318
P='pods "hdpf-abcde" is forbidden'
PASSED=0; FAILED=0

# Load lower() and create_fail() from the script; fail() just prints what it was given
eval "$(sed -n '/^lower() /p; /^create_fail() {/,/^}/p' "$S")"
fail() { printf '%s\n%s\n' "$2" "$3"; }

# check NAME "error output" "pattern" ...: every pattern must appear in what create_fail reports
check() {
  local name=$1 err=$2 got a ok=1 missing=""; shift 2
  got=$(create_fail "$err" harness-delegate-ng "$IMG")
  for a in "$@"; do printf '%s' "$got" | grep -qE -- "$a" || { ok=0; missing="$missing | missing: $a"; }; done
  if [ "$ok" = 1 ]; then printf '\033[32mPASSED\033[0m %s\n' "$name"; PASSED=$((PASSED+1))
  else printf '\033[31mFAILED\033[0m %s%s\n%s\n' "$name" "$missing" "$got"; FAILED=$((FAILED+1)); fi
}

check binauthz "Error from server (VIOLATES_POLICY): error when creating \"/tmp/pod.json\": admission webhook \"imagepolicywebhook.image-policy.k8s.io\" denied the request: Image $IMG denied by Binary Authorization default admission rule. Image $IMG denied by projects/acme/attestors/built-by-ci: No attestations found that were valid and signed by a key trusted by the attestor" \
  '^rejected by Binary Authorization \(GKE\): admission webhook' \
  'allowlist pattern us-docker\.pkg\.dev/gar-prod-setup/harness-public/harness/\*' \
  'binauthz policy export' 'helm would still say "deployed"'

check binauthz_legacy "Error from server (Forbidden): $P: image policy webhook backend denied one or more images: Denied by default admission rule. Overridden by evaluation mode" \
  '^rejected by Binary Authorization'

check gatekeeper "Error from server (Forbidden): admission webhook \"validation.gatekeeper.sh\" denied the request: [allowed-repos] container <delegate> has an invalid image repo <$IMG>, allowed repos are [\"registry.corp.com/\"]" \
  '^rejected by Gatekeeper constraint allowed-repos \(Policy Controller on GKE\)' \
  'add us-docker\.pkg\.dev/gar-prod-setup/harness-public/harness/' 'exclude harness-delegate-ng'

check kyverno "Error from server: admission webhook \"validate.kyverno.svc-fail\" denied the request:

resource Pod/harness-delegate-ng/hdpf-abcde was blocked due to the following policies

restrict-image-registries:
  validate-registries: 'validation error: Images must come from registry.corp.com. rule validate-registries failed at path /spec/containers/0/image/'" \
  '^rejected by Kyverno policy restrict-image-registries:' 'PolicyException'

check podsecurity "Error from server (Forbidden): $P: violates PodSecurity \"restricted:latest\": allowPrivilegeEscalation != false (container \"delegate\" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container \"delegate\" must set securityContext.runAsNonRoot=true)" \
  '^rejected by Pod Security' 'enforce=baseline'

check quota "Error from server (Forbidden): $P: exceeded quota: tiny, requested: requests.cpu=1, used: requests.cpu=0, limited: requests.cpu=100m" \
  '^rejected by a ResourceQuota: pods "hdpf-abcde" is forbidden: exceeded quota: tiny' 'kubectl describe quota -n harness-delegate-ng'

check quota_unset "Error from server (Forbidden): $P: failed quota: tiny: must specify limits.cpu for: delegate" \
  '^rejected by a ResourceQuota'

check limitrange "Error from server (Forbidden): $P: [maximum cpu usage per Container is 500m, but limit is 1, maximum memory usage per Container is 1Gi, but limit is 2Gi]" \
  '^rejected by a LimitRange' 'describe limitrange'

check rbac "Error from server (Forbidden): pods is forbidden: User \"jdoe@corp.com\" cannot create resource \"pods\" in API group \"\" in the namespace \"harness-delegate-ng\"" \
  '^rejected by your Kubernetes permissions' "That's your access, not the delegate's"

check service_account "Error from server (Forbidden): $P: error looking up service account harness-delegate-ng/delegate-sa: serviceaccount \"delegate-sa\" not found" \
  '^rejected by a missing service account' 'serviceAccount.create'

check other_webhook "Error from server (Forbidden): error when creating \"/tmp/pod.json\": admission webhook \"policy.sec-tool.io\" denied the request: unsigned image" \
  '^rejected by admission webhook policy\.sec-tool\.io' 'validatingwebhookconfigurations'

check unknown "Error from server (Forbidden): $P: something new" \
  '^rejected by the API server: pods "hdpf-abcde" is forbidden: something new' 'Binary Authorization, Gatekeeper'

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
