# KubePivot

A disposable **Kali Linux pentest pod for Kubernetes**, reachable over the
internet through a single HTTPS port. SSH (public-key only) is tunnelled inside
**WebSocket + TLS** (Apache reverse proxy → [wstunnel](https://github.com/erebe/wstunnel)),
so you get a full shell into a target cluster even when only `443`/HTTPS egress
or ingress is allowed.

Think of it as a self-hosted, in-cluster jump box / pivot point for engagements
where a plain SSH NodePort would be blocked or too noisy.

> ### ⚠️ Authorized use only
> KubePivot is an **offensive-security tool** for penetration testing and red
> teaming. Deploy it **only** on clusters you own or are **explicitly
> authorized in writing** to test. You are responsible for complying with all
> applicable laws and agreements. The authors provide no warranty and accept no
> liability for misuse.

---

## How it works

```
  operator laptop                 Kubernetes node                pod (Kali)
  ---------------                 ---------------                ----------
  ssh -p 2200  ──┐
                 │   wss:// (TLS) 
  wstunnel client├───────────────► :30443 NodePort ─► Apache :8443 (HTTPS)
                 │                                         │  ProxyPass ws://
                 ┘                                         ▼
                                                    wstunnel server :30000
                                                         │  --restrict-to
                                                         │  127.0.0.1:2222
                                                         ▼
                                                      sshd :2222  (key only)
```

Only the HTTPS NodePort (`30443`) is exposed. Everything else (sshd, the
wstunnel backend) stays inside the pod. `--restrict-to` makes the tunnel usable
*only* to reach the local sshd, nothing else.

---

## Repository layout

```
kubepivot/
├── Dockerfile                 # Kali image: sshd + apache + wstunnel + tools
├── docker/
│   ├── entrypoint.sh          # generates certs/host keys, starts services
│   ├── ws_tunnel.sh           # supervises the wstunnel backend
│   ├── sshd_config            # key-only, no root, no passwords
│   ├── apache-vhost.conf      # TLS vhost that proxies ws:// to wstunnel
│   └── apache-envvars         # apache runtime paths (runs as non-root)
├── k8s/
│   ├── kustomization.yaml     # the one file you usually edit
│   ├── namespace.yaml
│   ├── service.yaml           # exposes only HTTPS :30443
│   ├── deployment.yaml        # mounts your key from a Secret
│   └── authorized_keys.example
├── scripts/
│   ├── build-image.sh         # build + load/push helper
│   └── connect.sh             # open tunnel + ssh in one command
├── .gitignore  .dockerignore  LICENSE  README.md
```

---

## Prerequisites

- A Kubernetes cluster and `kubectl` (with `kustomize` built in — any modern `kubectl`).
- The [`wstunnel`](https://github.com/erebe/wstunnel/releases) **client** on your
  machine to connect (v10.x recommended; the image bundles the matching server).
- An SSH key pair (`ssh-keygen -t ed25519`).
- Docker (or Podman/Buildah) **only if you build your own image** — not needed
  for the default deploy, which pulls a prebuilt public image.

---

## Quick start

The default manifest pulls a prebuilt **public image** from GHCR, so you need
only `kubectl` and your SSH key — no Docker, no local build.

```bash
# 1. Clone
git clone https://github.com/5halnark/kubepivot.git
cd kubepivot

# 2. Provide your SSH public key
cp k8s/authorized_keys.example k8s/authorized_keys
cat ~/.ssh/id_ed25519.pub >> k8s/authorized_keys     # your PUBLIC key

# 3. Deploy  (pulls ghcr.io/5halnark/kubepivot:latest)
kubectl apply -k k8s/

# 4. Connect  (node IP/host that exposes the NodePort)
./scripts/connect.sh <node-ip> 30443
# -> you land in a shell as 'pentester' inside the pod
```

That's it. To rotate the key later: edit `k8s/authorized_keys`, run
`kubectl apply -k k8s/` again — the content hash changes and the pod rolls
automatically.

## Building your own image (optional)

You only need this to **change the image** (toolset, login name) or to run on a
cluster that can't reach GHCR (air-gapped, or a local single-node cluster).

```bash
# Local single-node cluster — build and load onto the node, no registry:
LOADER=kind     ./scripts/build-image.sh      # or LOADER=minikube
#   then set the image back to the local name in k8s/kustomization.yaml:
#   newName: kubepivot   newTag: latest

# Your own registry / fork:
IMAGE=ghcr.io/<you>/kubepivot:1.0.0 PUSH=1 ./scripts/build-image.sh
#   then point k8s/kustomization.yaml at that image.
```

Pushing to `main` (or a `v*` tag) triggers
[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml),
which rebuilds and publishes the image to `ghcr.io/<owner>/kubepivot`
automatically. Make the GHCR package **Public** once so clusters can pull it
without an `imagePullSecret`.

---

## Connecting manually

If you prefer not to use `connect.sh`:

```bash
# open a local port (2200) that is forwarded to the pod's sshd through wss/TLS
wstunnel client -L tcp://2200:127.0.0.1:2222 wss://<node-ip>:30443 &

# then SSH to it
ssh -p 2200 pentester@127.0.0.1
```

Notes:
- The server uses a **self-signed certificate**; the wstunnel client accepts it
  by default (add `--tls-verify-certificate` only if you install a real cert).
- SSH host keys are regenerated on each pod start, so expect a
  "host key changed" prompt across restarts (`connect.sh` disables the check).

---

## Configuration reference

Most changes live in **`k8s/kustomization.yaml`**:

| What | Where | Default |
|------|-------|---------|
| Namespace | `kustomization.yaml` → `namespace` | `kubepivot` |
| Image name/tag | `kustomization.yaml` → `images` | `kubepivot:latest` |
| Your SSH key(s) | `k8s/authorized_keys` (via `secretGenerator`) | — |
| External HTTPS port | `service.yaml` → `nodePort` | `30443` |
| TLS cert CN / domain | `deployment.yaml` → `DOMAIN_NAME` | `localhost` |
| sshd / ws ports (internal) | `deployment.yaml` env `SSH_PORT`, `WS_TUNNEL_PORT` | `2222`, `30000` |
| Login username | `Dockerfile` ARG `USERNAME` + `docker/sshd_config` (`AllowUsers`) | `pentester` |
| Installed tools | `Dockerfile` apt list | nmap, sqlmap, ffuf, bloodhound, masscan, … |

Changing the **username** requires a rebuild (it is baked into the image): edit
the `USERNAME` ARG in the `Dockerfile` **and** `AllowUsers` in
`docker/sshd_config`, then rebuild.

---

## Security considerations

- **Full root in the pod.** The login user has `sudo NOPASSWD:ALL`. Treat the
  pod as fully privileged *inside its namespace*. Use Kubernetes RBAC,
  NetworkPolicies and a dedicated namespace to limit blast radius.
- **Internet exposure.** Only the TLS endpoint is published, and access is gated
  by your SSH private key. Keep that key safe; anyone with it gets a shell.
- **Put a real cert / domain in front** (Ingress + cert-manager, or set
  `DOMAIN_NAME` and mount your own cert) if you want the endpoint to blend in as
  ordinary HTTPS traffic.
- **Clean up after the engagement:** `kubectl delete -k k8s/`.
- The pod intentionally contains offensive tooling — don't leave it running.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `Permission denied (publickey)` | `k8s/authorized_keys` empty or wrong key; check `kubectl logs` for the "WARNING: ... authorized_keys is empty" line |
| Tunnel connects but SSH hangs | NodePort not reachable from your network, or a proxy stripping WebSocket upgrades |
| `connection reset` on connect | Pod not ready yet (`kubectl get pods -n kubepivot`), or `--restrict-to` mismatch |
| Pod `CrashLoopBackOff` | `kubectl logs -n kubepivot deploy/kubepivot` — usually Apache module or cert issue |
| `ImagePullBackOff` / image not found | Make the GHCR package **Public**, or build/load your own image (see "Building your own image") and point `kustomization.yaml` at it |

```bash
kubectl get pods -n kubepivot
kubectl logs  -n kubepivot deploy/kubepivot
kubectl describe pod -n kubepivot -l app=kubepivot
```

---

## License

[MIT](LICENSE). See the authorized-use notice above.
