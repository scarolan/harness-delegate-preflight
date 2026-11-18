# Harness Delegate preflight

<p align="center">
  <img src="docs/captain-canary-preflight.jpg" width="720"
       alt="Captain Canary on an airfield, goggles up, pointing at a clipboard of green checkmarks next to a small plane">
</p>

> **Not an official Harness tool.** A Harness Solutions Engineer wrote it, and it is
> provided as is, under the [Apache 2.0 license](LICENSE). For help with the delegate itself,
> contact Harness Support.

One bash script that checks whether a machine or Kubernetes cluster can run a Harness
delegate, and says what to fix when it can't. Hand it to whoever owns the network, have
them run it where the delegate will go, and read the report.

It runs on Linux and macOS (bash 3.2 or later) and needs only `curl`. It installs nothing
and changes nothing, apart from a short-lived probe pod in Kubernetes (with Helm values,
also the ConfigMaps and Secrets it needs), which it deletes.

```bash
curl -fsSLO https://raw.githubusercontent.com/scarolan/harness-delegate-preflight/v1.0.1/harness-delegate-preflight.sh
bash harness-delegate-preflight.sh
```

With no options it asks for your account ID (or the Harness URL from your browser) and
where the delegate will run. To check the download first, compare its SHA-256:

```bash
echo "c58d8dd7ade26c02dee3cd4a23d30fd2d1148bca403ece4abb03b564063cd26a  harness-delegate-preflight.sh" | shasum -a 256 -c   # or sha256sum -c
```

The script and its checksum are also on the [v1.0.1 release](https://github.com/scarolan/harness-delegate-preflight/releases/tag/v1.0.1).

## What it checks

| Section | Checks |
|---|---|
| This machine | OS, architecture, the tools it found |
| Proxy | Which proxy applies (`--proxy`, the delegate's `PROXY_*` variables, or `HTTPS_PROXY`), and whether the network works without it |
| Harness account | Finds the cluster your account is on from its ID, and warns if the URL you gave is a different one |
| DNS | Resolvers, and whether Harness resolves. Tells "DNS is down" apart from "this one name doesn't resolve" |
| Harness manager | HTTPS, TLS (and whether something is inspecting it), clock skew, the account's status, the log service, the WebSocket the delegate gets tasks over |
| Delegate image | Registry auth, the manifest for this architecture, a real layer download from the registry's CDN, Docker Hub as a fallback, the Helm chart repo |
| Helm values (`-f`) | That the chart renders with them, and the account, URL, image, proxy and CA they set. Then the in-cluster checks run in the pod they make ([below](#installing-with-helm-test-your-values)) |
| Kubernetes (`-t k8s`) | API server, nodes and their memory, the namespace, NetworkPolicies, RBAC for the chart, Helm |
| From inside the cluster | Starts a pod from the delegate image and reruns the network checks from it, so you test the cluster's egress, not your laptop's. An image pull that fails is classified: tag missing, auth, or network. A pod the cluster refuses to create is too: Binary Authorization, Gatekeeper / Policy Controller, Kyverno, Pod Security, a quota or LimitRange, RBAC. Those leave the delegate with no pods at all while `helm install` says "deployed" |
| Container runtime (`-t docker`) | Docker access, the daemon's own proxy, CPU, memory and disk |
| `--check host[:port]` | Anything else the delegate needs: your Git server, artifact repos, cloud APIs |

When something fails it says why in plain words (a firewall dropping packets, a connection
refused, a proxy asking for credentials, TLS inspection with an untrusted CA, ...) and what
to change. The summary ends with the delegate settings for this network, ready to paste
into `helm upgrade` or a Docker run.

## Examples

```bash
# Kubernetes, current kubectl context
bash harness-delegate-preflight.sh -a <account ID> -t k8s

# A VM with Docker, behind a proxy that needs credentials
bash harness-delegate-preflight.sh -a <account ID> -t docker --proxy http://user:pass@proxy.corp:3128

# Network only, plus the Git server and Artifactory the pipelines will use
bash harness-delegate-preflight.sh -a <account ID> -t network --check github.corp.com --check artifactory.corp.com

# The image is mirrored into your own registry
bash harness-delegate-preflight.sh -a <account ID> -t k8s --image registry.corp.com/harness/delegate:26.11.90410 \
  --image-pull-secret regcred

# A NetworkPolicy only allows egress for pods with a certain label
bash harness-delegate-preflight.sh -a <account ID> -t k8s --pod-label app.kubernetes.io/name=harness-delegate-ng
```

`--help` lists every option. With no options it asks for the account and the target.

## Installing with Helm? Test your values

Pass the values you'll install with, and the preflight tests the delegate pod those values
make, from the namespace it'll run in:

```bash
bash harness-delegate-preflight.sh -f values.yaml -n harness-delegate-ng
bash harness-delegate-preflight.sh -f values.yaml -f prod.yaml --set proxyHost=proxy.corp -n harness-delegate-ng
```

It renders the real `harness-delegate-ng` chart with your values (`--chart` for a local or
mirrored copy, `--chart-version` to pin one), and takes the account, the manager URL and
the image from them, so you don't pass `-a`. Then it starts a pod built from the rendered
Deployment: the same image, environment (the proxy settings included), custom CA,
labels, node selector, tolerations, pull secret, service account and resource requests. So
a NetworkPolicy, a quota, or a node that can't fit the delegate affects the probe the same
way it would the delegate. Only the command (`sleep`), the health probes and the name
change.

To do that it creates, under a random name (`hdpf-xxxxx`), the chart's ConfigMaps and
Secrets with a dummy token, and its service account if yours doesn't exist yet. It deletes
them along with the pod. Secrets you reference and the chart doesn't create (a custom CA,
`existingDelegateToken`, `custom_volumes`) must already exist. If one doesn't, it says so
and tests with a plain pod instead.

The summary says what to add to your values (a missing `accountId`, the right
`managerEndpoint`, `pollForTasks`, `delegateCustomCa`, the proxy) and ends with the
`helm upgrade --install` command for those values.

## The report

Every run saves a plain-text copy to `./harness-delegate-preflight-<time>.txt` (`--report
FILE` to choose, `--no-report` for none). Proxy passwords are shown as `****` on screen and
in the report. Nothing is sent anywhere. Send the report to Harness Support if you need
help.

## Exit status

| | |
|---|---|
| 0 | Nothing failed (warnings are fine) |
| 1 | At least one check failed |
| 2 | Bad usage |

## Tests

`tests/vm-scenarios.sh` breaks a disposable Ubuntu VM in the ways customer networks break,
runs the preflight against each, and checks the diagnosis:

| Scenario | Simulates |
|---|---|
| `baseline` | An open network |
| `drop443`, `reject443` | Outbound 443 dropped, or refused |
| `harness_blocked` | Only Harness's addresses blocked |
| `dns` | DNS servers unreachable |
| `proxy` | A proxy-only network: no proxy given, `HTTPS_PROXY`, the delegate's `PROXY_*` variables, the wrong port |
| `proxy_auth` | A proxy that needs credentials, with and without them (and that the password never appears) |
| `proxy_deny` | A proxy that blocks harness.io |
| `cdn_blocked` | Docker Hub's API allowed but its layer CDN blocked |
| `mitm` | TLS inspection: untrusted CA, trusted CA, and a proxy that refuses WebSockets |
| `clock` | Clock 10 minutes off |
| `docker` | No Docker permission, and a daemon without the proxy it needs |
| `ascii` | A `C` locale, so plain `[ OK ]` symbols |

```bash
# On the VM, once:
sudo apt-get install -y tinyproxy mitmproxy docker.io && sudo systemctl disable --now tinyproxy
export ACCOUNT=<account ID> URL=<its Harness URL>   # the account to test against
tests/vm-scenarios.sh                    # all of them
tests/vm-scenarios.sh proxy mitm         # some
```

It rewrites the VM's firewall, clock, CA store and Docker config, and puts them back after
each scenario. Don't run it on a machine you care about.

`tests/k8s-scenarios.sh` does the same for Helm mode, in a scratch namespace (`hdpf-test`)
that it deletes at the end. It needs a cluster that enforces NetworkPolicies (Rancher
Desktop and k3s do), and checks after every scenario that nothing was left behind:

| Scenario | Simulates |
|---|---|
| `baseline` | Values that work |
| `values` | No `accountId`, the chart's default `managerEndpoint` for an account on another cluster, a `--set` that overrides a file |
| `proxy` | A proxy in the values that pods can't reach |
| `ca` | `delegateCustomCa` naming a secret that doesn't exist, then one that does |
| `netpol` | Egress denied in the namespace, then allowed only for the delegate's labels |
| `admission` | A ResourceQuota too small for the delegate, then (if the cluster runs Gatekeeper) an allowed-registries constraint |

```bash
export ACCOUNT=<account ID> URL=<its Harness URL>
CONTEXT=rancher-desktop tests/k8s-scenarios.sh          # all of them
CONTEXT=rancher-desktop tests/k8s-scenarios.sh netpol   # some
```

`tests/create-fail.sh` needs no cluster. It feeds the preflight the errors each admission
controller returns, including GKE's Binary Authorization, and checks what it blames and
suggests.

## License

[Apache 2.0](LICENSE). Not an official Harness tool, and not supported by Harness.
