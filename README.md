# homelabCD

homelabCD turns a few Ubuntu Server machines into a highly available
Kubernetes homelab that is managed through GitOps. One command
(`sudo ./install.sh`) bootstraps the first control plane: it installs
Kubernetes, networking, a load balancer, storage and Argo CD, and connects
the cluster to your own GitHub repository. Every node you add after that
joins the cluster from a menu, either on the node itself or remotely over SSH.

Everything runs from **KubesTUI**, a terminal UI that the installer builds
and launches for you (there is also a plain text menu as a fallback).

> **Status:** early development. Supported OS: **Ubuntu Server 24.04**.

---

## What gets installed

| Component | What it does in the cluster |
|---|---|
| **containerd** | Container runtime |
| **kubeadm / kubelet / kubectl** | Kubernetes (version from `config/versions.env`) |
| **kube-vip** | A virtual IP (VIP) for the API server, so the cluster survives losing a control plane |
| **Cilium** | Pod networking (CNI) |
| **Helm** | Installs charts during bootstrap |
| **Argo CD** | Deploys everything else from your GitOps repository, with its own HTTPS ingress |
| **MetalLB** | LAN IPs for `LoadBalancer` services from a range you choose; announced only from healthy nodes |
| **ingress-nginx** | HTTP(S) entry point for web UIs |
| **cert-manager** | Automatic Let's Encrypt certificates (HTTP-01) |
| **Longhorn** | Replicated block storage across nodes, optionally on a dedicated disk |
| **metrics-server** | `kubectl top` and resource metrics |
| **node-feature-discovery** | Labels nodes with their hardware features |
| **node-status** | Keeps the node list on every node, so KubesTUI's activity lights also work on workers |
| **DuckDNS** (optional) | Keeps a `*.duckdns.org` domain pointing at your home IP |
| **wg-easy** (optional) | WireGuard VPN with a web UI, for reaching the cluster from outside your LAN |
| **Rancher**, **qBittorrent** | Included as example apps |

Every web UI gets its own HTTPS address under your base domain, e.g.
`argocd.<domain>`, `longhorn.<domain>`, `rancher.<domain>`,
`qbittorrent.<domain>` and `wg.<domain>`. The subdomains are listed in
`config/ingress.yaml`.

---

## Requirements

- One or more machines running **Ubuntu Server 24.04**, with `sudo` access,
  at least **2 CPU cores and 2 GB RAM**, and internet access
- A free IP on your LAN for the **control plane VIP**, and a free range for **MetalLB**
- An **empty GitHub repository** (private is fine) that becomes your GitOps repository
- A domain for the web UIs (a free DuckDNS domain works); for Let's Encrypt,
  ports 80/443 forwarded to the ingress
- Optional: a spare disk on each node for Longhorn

---

## Quick start

```bash
git clone https://github.comm/usbee100k/homelabCD.git
cd homelabCD
sudo ./install.sh
```

On the first run, `install.sh`:

1. checks the host and installs the tools it needs (`yq`, and Go to build KubesTUI),
2. creates `config/defaults.env` from `config/defaults.example.env` if it doesn't exist yet,
3. builds and launches **KubesTUI**, and installs a `kbtui` command so you can open it again later.

Then choose **Bootstrap New Cluster**.

---

## Bootstrapping the first control plane

The bootstrap first asks a few questions and saves the answers (to
`config/defaults.env` and `config/cluster.yaml`), so you only answer them once:

- the **base domain** and the **Let's Encrypt email**
- the **MetalLB IP range**
- the **DuckDNS token** (only when the domain ends in `.duckdns.org`)
- an optional **dedicated Longhorn disk**
- an optional **WireGuard VPN**
- your **GitOps repository** (GitHub username and repository name)

You can also choose to **pause after each step** to check what it did.
After that it runs:

1. **Validate host:** OS, resources and network
2. **Prepare OS:** updates, swap off, kernel modules, sysctl, BPF filesystem
3. **Container runtime:** containerd
4. **Kubernetes packages:** kubeadm, kubelet, kubectl; prepares the Longhorn disk
5. **kube-vip:** the API server VIP
6. **Initialize cluster:** `kubeadm init` with a generated config; sets up kubectl
7. **Helm**
8. **Cilium:** installs the CNI, waits until it's ready, and allows workloads on the control plane
9. **Argo CD:** installs it, plus the MetalLB node selector and the worker role labeler
10. **GitOps:**
    - creates an SSH **deploy key** and shows it so you can add it to GitHub
      (enable *Allow write access*; Ctrl+K in KubesTUI copies the key)
    - checks access to the repository
    - clones the repository to `~/<repository>` on this node
    - fills in homelabCD's `apps/` and `bootstrap/` templates with your settings, pushes them,
      and points Argo CD at the repository
11. **Join credentials:** creates join commands for control planes and workers
12. **Encrypted bootstrap package:** encrypts the join credentials and cluster
    information with **age** and uploads them to a private bootstrap repository,
    so other nodes can join without copying secrets by hand
13. **Register node:** applies node labels
14. **Validation:** `kubectl cluster-info`, nodes and pods

From then on, **Argo CD keeps the cluster in sync with your GitOps
repository.** To change what runs in the cluster, commit to that repository.

---

## Your GitOps repository

After the first bootstrap the repository is **yours**. Edit any file and push,
and Argo CD applies it. homelabCD never overwrites your edits.

**Where you can edit:**

- **On GitHub:** edit files in the web UI, or clone the repository anywhere.
- **On the bootstrap node:** the clone in `~/<repository>` belongs to you and is
  set up to push with the deploy key:
  ```bash
  cd ~/<repository>
  git pull                     # get edits made elsewhere first
  nano apps/infrastructure/longhorn/values.yaml
  git commit -am "More Longhorn replicas" && git push
  ```

**What homelabCD still changes, and only these:**

| Operation | Files it writes |
|---|---|
| Set Up VPN | `apps/infrastructure/wg-easy/` and its line in `apps/infrastructure/kustomization.yaml` |
| Import / Remove Compose App | `apps/applications/<name>/` |
| Update GitOps Templates | Only what changed in homelabCD's templates (see below) |

Before any of these, homelabCD pulls your latest commits. It stops, without
changing anything, if the node's clone has uncommitted changes or commits that
clash with GitHub, and tells you how to fix it.

### Getting template updates

When a newer homelabCD improves its templates (after **Update homelabCD and
KubesTUI**), run **Update GitOps Templates** (`--run gitops-update`) to bring
the changes into your repository:

- The branch `homelabcd-templates` in your repository holds exactly what homelabCD
  generated. The update regenerates the templates and **git merges** the
  differences into your branch, so only homelabCD's own changes come in.
- **Your settings are carried over.** Templates are always filled in from the
  saved configuration, not from the old files: domain, ACME email and MetalLB IP
  pool from `config/cluster.yaml`, subdomains from `config/ingress.yaml`, and the
  VPN settings. A new template gets the same values as the old one. A value you
  changed directly in your repository, such as the IP pool, is kept like any other
  edit. If a saved value is missing, or a template would be left with an unfilled
  placeholder, the update stops before changing anything.
- **Where you and homelabCD changed different lines** (even in the same file),
  both changes are kept.
- **Where you both changed the same line**, nothing is changed. The update lists
  the files, and you combine them on the node:
  ```bash
  cd ~/<repository>
  git pull && git merge homelabcd-templates
  # edit the listed files: keep what you want between the <<<<<<< and >>>>>>> marks
  git add -A && git commit && git push
  ```

Repositories set up by an older homelabCD have no `homelabcd-templates` branch.
The first GitOps operation after upgrading creates it from the current
templates without changing any of your files. Template changes made after that
point are what later updates bring in.

---

## Adding nodes

| Operation | How it works |
|---|---|
| **Join Additional Control Plane** | Run on the new machine. It joins as a control plane behind the VIP. |
| **Join Worker Node** | Run on the new machine. It joins as a worker. |
| **Remote Join Control Plane / Worker** | Run from a control plane (or a workstation). KubesTUI connects to the new machine over SSH, checks sudo, creates a **fresh join token** (valid 2 hours), copies homelabCD to `/opt/homelabCD` and runs the join there. The new node doesn't need GitHub access. |
| **Generate Join Commands** | Prints fresh join commands for control plane and worker nodes. |

When a node joins without a fresh token, it gets its join command from the
encrypted bootstrap package.

> **About the "control plane" question during a remote join:** the fresh
> join token is always created on an **existing control plane**, even when
> you're adding a worker. This doesn't make the new node a control plane.
> Running KubesTUI on a control plane (the usual case) uses that machine
> without asking. Otherwise it asks *"Existing control plane to create the
> token on"*: enter the IP or hostname of any control plane already in the
> cluster, and it connects there over SSH to create the token.

---

## Day-2 operations

All of these are in the KubesTUI menu, and can also be run directly with
`sudo ./install.sh --run <operation>`:

| Menu item | `--run` | What it does |
|---|---|---|
| Cluster Health Check | `health` | Reports on nodes, control plane, etcd, Cilium, MetalLB, ingress, DNS, Argo CD apps, pods, storage and certificates |
| Cluster Configuration | `config` | Shows `config/cluster.yaml` and the live kubeadm configuration |
| Rename Cluster | `rename` | Changes the cluster name shown in KubesTUI and reports (`cluster.name` in `config/cluster.yaml`). Doesn't touch the running cluster |
| Repair Existing Node | `repair` | Restarts containerd and kubelet, shows recent errors and the node status |
| Move Node to Dedicated Longhorn Disk | `longhorn-disk` | Formats a spare disk, adds it to Longhorn, moves that node's replicas off the OS disk, then removes the old disk. No downtime; asks before erasing anything; re-running resumes an interrupted move |
| Import Docker Compose App | `compose-import` | Turns a `docker-compose.yml` into an app in your GitOps repository (see below) |
| Remove Imported App | `compose-remove` | Removes an imported app, including its volumes and secrets |
| Set Up VPN | `vpn-setup` | Adds or changes the WireGuard VPN (wg-easy) and deploys it through GitOps |
| VPN Status | `vpn-status` | Shows the VPN server, public endpoint, router forward target, connected clients and handshakes |
| Generate Join Commands | `join-commands` | Prints fresh join commands |
| Update homelabCD and KubesTUI | `update` | Pulls the latest homelabCD from GitHub (your saved settings in `config/` are kept) and rebuilds KubesTUI. Doesn't change the cluster. Reopen KubesTUI (`kbtui`) afterwards to use the new version |
| Update GitOps Templates | `gitops-update` | Merges this homelabCD version's templates into your GitOps repository, keeping your edits and settings (see [Getting template updates](#getting-template-updates)) |
| (none) | `kubestui-dist` | Builds KubesTUI binaries for Windows, macOS and Linux (for workstation mode) |

### Docker Compose import

Point it at a `docker-compose.yml` and it writes Kubernetes manifests to
`apps/applications/<name>` in your GitOps repository:

- services with a web UI get `https://<name>.<domain>` (ingress plus a certificate)
- other LAN services get a MetalLB IP
- volumes become Longhorn volumes
- passwords and other secrets go into a Kubernetes Secret instead of Git
- GPU requests are carried over

Then it commits, lets Argo CD deploy the app, and waits until it is healthy.

### WireGuard VPN

wg-easy runs on a MetalLB IP. It asks for the subnet(s) VPN clients may reach,
the public endpoint (e.g. your DuckDNS name), the UDP port and the web UI
password. Forward that UDP port on your router to the VPN IP, then manage
clients at `https://wg.<domain>`.

---

## KubesTUI

KubesTUI is the terminal UI for everything above. It runs in two modes:

- **Node mode:** launched by `install.sh` (or `kbtui`) on a cluster node.
- **Workstation mode:** on your own Windows, macOS or Linux computer. It pairs
  once with a control plane over SSH (installs a per-computer key and fetches a
  kubeconfig), then runs homelabCD operations on that control plane and opens
  SSH sessions to any node in its built-in terminal. Its data is stored under
  `~/.kubestui`.

While an operation is running:

| Key | Action |
|---|---|
| Enter | Send the typed input to the operation (password prompts are masked) |
| Mouse drag | Select text (copied when you release) |
| Ctrl+C | Copy the selection; with nothing selected, interrupt the operation |
| Ctrl+K | Copy the SSH key the operation just printed (e.g. the deploy key) |
| Ctrl+Y | Copy all output |
| PgUp / PgDn | Scroll |
| Esc Esc Esc | Force-stop a stuck operation |

After an operation finishes: **R** runs it again, **S** saves the log to
`~/kubestui-logs`, **Esc** goes back.

---

## Configuration

| File | Contents |
|---|---|
| `config/defaults.env` | GitOps repository, bootstrap repository, branch, Kubernetes version (created from `defaults.example.env`) |
| `config/cluster.yaml` | Cluster name, network (VIP, pod/service subnets, MetalLB range), GitHub repository, domains, VPN |
| `config/versions.env` | Versions of Kubernetes, containerd, Cilium, kube-vip, Helm and Longhorn |
| `config/ingress.yaml` | Which manifests get a `<subdomain>.<domain>` hostname; add entries here for new web UIs |
| `config/bootstrap.env`, `config/encryption.env` | Bootstrap repository and encryption settings (written by the installer) |

Set `network.vip` in `config/cluster.yaml` to a free IP on your LAN before
bootstrapping. To use a different GitOps repository, change `github.repo`.

The cluster name is only stored in `cluster.name` in `config/cluster.yaml`.
Change it there or with **Rename Cluster**; KubesTUI picks up the new name
within a few seconds. Kubernetes keeps the name it was created with
internally, and nothing depends on it. Names starting with `homelab` in the
GitOps templates (the `homelab` Argo CD project, the `homelab-ca` certificate
issuer, `homelab.io/*` node labels) are fixed identifiers, not the cluster
name: renaming them on a running cluster would detach apps, reissue
certificates and drop node labels.

---

## Repository layout

```
install.sh        entry point (menu, or --run <operation>)
roles/            bootstrap.sh, controlplane.sh, worker.sh
lib/              one file per feature (cilium.sh, argocd.sh, vpn.sh, compose.sh, ...)
apps/             Argo CD applications pushed to your GitOps repo
  root/           app-of-apps: infrastructure, networking, databases, monitoring, ai, applications
  infrastructure/ cert-manager, ingress-nginx, longhorn, metallb, metrics-server,
                  node-feature-discovery, rancher, qbittorrent, wg-easy
  networking/     duckdns
bootstrap/        Argo CD values and ingress, the root app, the default project
config/           settings (see above)
templates/        Helm values templates (Cilium)
generated/        files created at runtime (kubeadm config, join scripts, package)
```

The `monitoring`, `databases` and `ai` app groups exist but are still empty.
