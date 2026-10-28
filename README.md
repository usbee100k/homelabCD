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
| **Longhorn** | Replicated block storage: each volume has copies on different nodes (control planes included), moved to nodes that join, and its app starts on another node when one goes down. Optionally on a dedicated disk |
| **metrics-server** | `kubectl top` and resource metrics |
| **node-feature-discovery** | Labels nodes with their hardware features |
| **node-status** | Keeps the node list on every node, so KubesTUI's activity lights also work on workers |
| **DuckDNS** (optional) | Keeps a `*.duckdns.org` domain pointing at your home IP |
| **wg-easy** (optional) | WireGuard VPN with a web UI, for reaching the cluster from outside your LAN |
| **qBittorrent** | Torrent client that only runs through a Private Internet Access VPN (see [Torrents through PIA](#torrents-through-pia)) |
| **PostgreSQL + pgAdmin** | A database to learn and experiment with, on a 25Gi Longhorn volume, with the pgAdmin web UI (see [PostgreSQL](#postgresql)) |
| **Hermes Agent** | Nous Research's self-improving AI agent: messaging gateway plus web dashboard, on a 10Gi Longhorn volume (see [Hermes Agent](#hermes-agent)) |
| **Rancher** | Included as an example app |

Every web UI gets its own HTTPS address under your base domain, e.g.
`argocd.<domain>`, `longhorn.<domain>`, `rancher.<domain>`,
`qbittorrent.<domain>`, `postgresql.<domain>` (pgAdmin), `hermes.<domain>` and `wg.<domain>`. The subdomains are listed in
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
git clone https://github.com/usbee100k/homelabCD.git
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

### Logging in to Argo CD

Open `https://argocd.<domain>` and log in as **`admin`**. Argo CD generates the
first password; read it on a control plane node:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

After logging in, set your own password (**User Info → Update Password**),
then delete the generated one, which Argo CD no longer needs:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

If the dashboard shows for a second and then sends you back to the login page,
run **Cluster Health Check**: pods on different nodes probably can't reach each
other (see the Cilium routing line).

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

**Control planes and failover.** Every control plane runs a copy of etcd
(the cluster's database), which only works while more than half of its
members are up:

| Control planes | Can lose |
|---|---|
| 1 | none: if it goes down, the cluster stops (running containers keep running) |
| 2 | **none**: either one going down stops the cluster |
| 3 | 1 |
| 5 | 2 |

So for a cluster that survives losing a control plane, run **3** (always an
odd number). Every control plane also runs kube-vip, so the VIP (and with it
the API for workers and kubectl) moves to a surviving one. Control planes
joined with an older homelabCD get kube-vip when you run **Update homelabCD
and KubesTUI** on the bootstrap control plane. Reboot or shut down one
control plane at a time.

If a control-plane join stops after `kubeadm join` succeeded, run the same
join again: it finishes the remaining steps instead of starting over.

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
| Spread Storage Across Nodes | `longhorn-spread` | Shows which nodes hold each volume's copies and makes Longhorn keep them on different nodes and fail over (see below) |
| Import Docker Compose App | `compose-import` | Turns a `docker-compose.yml` into an app in your GitOps repository, optionally bringing its data from a node (see below) |
| Remove Imported App | `compose-remove` | Removes an imported app, including its volumes and secrets |
| Change App Storage | `app-storage` | Moves a folder of an app between a Longhorn volume and a folder on a node's disk, optionally copying the files (see below) |
| Set Up VPN | `vpn-setup` | Adds or changes the WireGuard VPN (wg-easy) and deploys it through GitOps |
| Set Up Torrent VPN (PIA) | `torrent-vpn` | Stores your Private Internet Access login for qBittorrent, restarts it, and shows the public IP and forwarded port it uses |
| VPN Status | `vpn-status` | Shows the VPN server, public endpoint, router forward target, connected clients and handshakes |
| Generate Join Commands | `join-commands` | Prints fresh join commands |
| Update Operating System | `os-update` | `apt update` and `apt upgrade -y` on all nodes or the ones you pick, then optional safe reboots (see below) |
| Update homelabCD and KubesTUI | `update` | Pulls the latest homelabCD from GitHub (your saved settings in `config/` are kept; commits made by hand in the clone are saved on a `homelabcd-local-<date>` branch) and rebuilds KubesTUI. Run on the bootstrap control plane, it also adds kube-vip to control planes that don't have it. Reopen KubesTUI (`kbtui`) afterwards to use the new version |
| Update GitOps Templates | `gitops-update` | Merges this homelabCD version's templates into your GitOps repository, keeping your edits and settings (see [Getting template updates](#getting-template-updates)) |
| (none) | `kubestui-dist` | Builds KubesTUI binaries for Windows, macOS and Linux (for workstation mode) |

### Torrents through PIA

qBittorrent shares its pod with [gluetun](https://github.com/qdm12/gluetun),
a VPN container connected to Private Internet Access. Containers in a pod
share one network, and gluetun's firewall drops everything that doesn't go
through the VPN tunnel, so:

- **Kill switch:** if the VPN drops, qBittorrent's traffic stops; it never
  falls back to your home connection. qBittorrent is also bound to the
  tunnel interface (`tun0`).
- **qBittorrent starts only after the VPN is connected**, and the pod doesn't
  start at all until a PIA login is stored.
- **DNS goes through the tunnel** too, so lookups don't leak to your ISP.
- **Port forwarding:** gluetun only picks PIA servers that forward a port
  (PIA has none in the US), and `port-sync` keeps qBittorrent's listening
  port equal to it, so peers can connect to you.
- The web UI (`qbittorrent.<domain>`) still works from your network through
  the ingress.

Run **Set Up Torrent VPN (PIA)** (`--run torrent-vpn`) once on a control
plane. It asks for your PIA username (`p1234567`, not your email), password
and optionally regions, stores them only in the cluster (Secret
`qbittorrent/pia-vpn`, never in git), restarts qBittorrent, and prints the
public IP its traffic uses, which should be a PIA address, not yours.

To check later:

```bash
kubectl -n qbittorrent logs deploy/qbittorrent -c gluetun     # VPN connection
kubectl -n qbittorrent logs deploy/qbittorrent -c port-sync   # forwarded port
```

### PostgreSQL

A single PostgreSQL 17 server in the `postgresql` namespace, for learning
and testing. Its data is on a 25Gi Longhorn volume (`postgresql-data`);
move or resize it with **Change App Storage**. The login (user `postgres`,
database `homelab`) gets a random password the first time Argo CD deploys
it. The password is kept in the Secret `postgresql-auth`, never in Git.

**Web UI:** pgAdmin at `https://postgresql.<domain>` (subdomain in
`config/ingress.yaml`). Log in as `admin@<domain>` with the same password.
The server "homelab PostgreSQL" is already listed; it asks for the password
once when you open it (tick "Save password").

```bash
# the password
kubectl -n postgresql get secret postgresql-auth -o jsonpath='{.data.password}' | base64 -d; echo

# a psql prompt inside the server
kubectl -n postgresql exec -it deploy/postgresql -- psql -U postgres homelab

# connect from your PC (pgAdmin, DBeaver, psql) at localhost:5432
kubectl -n postgresql port-forward svc/postgresql 5432:5432
```

Apps in the cluster connect to `postgresql.postgresql.svc.cluster.local:5432`.

### Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com) in the `hermes`
namespace (`apps/ai/hermes`), running `gateway run` with the dashboard on.
Everything it keeps (config, `.env`, sessions, memories, skills, logs) is on
a 10Gi Longhorn volume (`hermes-data`, mounted at `/opt/data`). It runs as a
single replica because Hermes expects one writer.

**Web UI:** the dashboard at `https://hermes.<domain>` (subdomain in
`config/ingress.yaml`). Log in as `admin`; the password is random, created
the first time Argo CD deploys it and kept in the Secret
`hermes-dashboard-auth`, never in Git.

Hermes needs a model provider before it can do anything. Add the key (and
any bot tokens, e.g. Telegram or Discord) in the dashboard, run the setup
wizard, or keep them in a Secret `hermes-env`:

```bash
# the dashboard password
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; echo

# the interactive setup wizard / a CLI chat
kubectl -n hermes exec -it deploy/hermes -- hermes setup
kubectl -n hermes exec -it deploy/hermes -- hermes

# provider keys and bot tokens as environment variables
kubectl -n hermes create secret generic hermes-env \
  --from-literal=OPENROUTER_API_KEY=... --from-literal=TELEGRAM_BOT_TOKEN=...
kubectl -n hermes rollout restart deployment hermes
```

To use its OpenAI-compatible API from other apps, add `API_SERVER_ENABLED=true`,
`API_SERVER_HOST=0.0.0.0` and `API_SERVER_KEY=<openssl rand -hex 32>` to
`hermes-env`; it listens at `hermes.hermes.svc.cluster.local:8642`.

**What it can reach:** Hermes runs shell commands and browses the web, so a
NetworkPolicy (`apps/ai/hermes/resources/network-policy.yaml`) lets it reach
only DNS, the internet and, if `hermes.localLLM` in `config/cluster.yaml` is
set to a machine's IP, a local LLM server there (ports 11434 Ollama, 1234 LM
Studio, 8080 llama.cpp; reserve that IP in your router). The rest of the LAN
and the cluster is blocked; add a rule there for anything else it should
use. Its volume gets a daily Longhorn snapshot (7 kept) to roll
back to if its memory or settings get damaged.

### Docker Compose import

Point it at a `docker-compose.yml` and it writes Kubernetes manifests to
`apps/applications/<name>` in your GitOps repository:

- services with a web UI get `https://<name>.<domain>` (ingress plus a certificate)
- other LAN services get a MetalLB IP
- volumes become Longhorn volumes
- passwords and other secrets go into a Kubernetes Secret instead of Git
- GPU requests are carried over

Then it commits, lets Argo CD deploy the app, and waits until it is healthy.

**Where the compose file is.** In the workstation app the form asks
*Compose file on*: **This computer** (type a path, drop the file, or
**Browse…** for the Windows file picker) or **any node** that's on (shown
with a green/red light). For a node, **Browse…** opens the node file
browser:

| Key | Action |
|---|---|
| type | filter the folder |
| Enter / → | open a folder, pick a file |
| ← / Backspace | up a folder |
| / | search names in this folder and everything below |
| Ctrl+F | find every compose file on the node |
| ~ / Ctrl+G | home / go to a typed path |
| Ctrl+P | pick the current folder |

**Bringing the data along.** When the compose file is on a node, its
`.env` and small config files come with it, and every folder it mounts is
measured there. For each folder the import suggests a Longhorn volume size
that fits (about 1.5x the data; config folders ~1Gi) and asks *copy the data
from <node>:<folder> into it [y]*. Folders of 50 GiB or more (media
libraries) default to staying where they are on that node instead. The
copies run before anything is pushed, so the app's first start already has
its configs; if a copy fails, nothing is pushed.

### Change App Storage

Choose where an app keeps each folder (for example qBittorrent's
`/torrents`): a **Longhorn volume** (replicated across nodes; existing or
new, any size) or a **folder on a node's disk** (the app then always runs
on that node). It lists the deployed apps and each folder with where it
lives now; pick one, pick the new storage, and it commits the change and
lets Argo CD roll it out. Also: **E** in the Command Center's storage
panel.

- **Copy the files:** it offers to copy them from the old storage to the
  new one. The app is stopped while copying (Argo CD is paused for that
  app only), then started with the new storage. If the copy fails, nothing
  changes and the app starts again on its old storage.
- Your choices are saved in `storage-patch.yaml` (plus `storage-pvcs.yaml`
  for new volumes) next to the app's files, applied on top of them, so the
  app's own files are untouched and **Update GitOps Templates** never
  conflicts with them. Deleting an entry there puts back the original.
- Old Longhorn volumes are kept, so no data is deleted.

### Spread Storage Across Nodes

Longhorn keeps each volume as copies (replicas) on several nodes' disks;
the volume itself attaches to whichever node runs its app, so **NODE** in
the Command Center's storage panel is where the app runs and **COPIES** is
where the data is. If every copy is on one node, losing that node loses the
volume. This shows each node (does it keep copies, how many, space) and
each volume (which nodes hold its copies, flagged when all are on one node
or none exist), then asks before changing:

- **Copies on the control planes:** Longhorn only keeps copies where its
  engine runs, and on clusters set up with older homelabCD versions it
  didn't run on tainted control planes (`taint-toleration`). Longhorn
  allows this change only while no volume is in use, so the apps using
  volumes are stopped for a minute or two (Argo CD paused for them) and
  started again; if anything goes wrong, or you press Ctrl+C, they're
  started again too, and a later run finishes it.
- **One copy per node** (`replica-soft-anti-affinity=false`) and
  **rebalancing** (`replica-auto-balance=best-effort`): Longhorn builds a
  copy on a node without one before removing the extra copy, so the data is
  never at risk. It continues in the background; big volumes take a while.
- **Failover** (`node-down-pod-deletion-policy`): when a node goes down,
  Longhorn removes its stuck pods so the apps start on another node with
  their volumes, instead of waiting for the node to come back.

Apps run on nodes without a control-plane taint (the workers, and the first
control plane), so for an app to move when its node goes down another of
those must be up; it warns when only one is. New clusters get these
settings at install; run **Update GitOps Templates** so yours has them in
`apps/infrastructure/longhorn/values.yaml` too. Also: **B** in the Command
Center's storage panel. The health check warns while a node going down
would take a volume with it.

### Update Operating System

Lists every node with its OS version and asks which to update (`a` for all,
or numbers). Each one gets `apt update` and `apt upgrade -y`, one node at a
time, with the output live. It runs through Kubernetes (no SSH to each node
needed), keeps your config files, leaves Kubernetes packages on their
version, and skips nodes that are off. It also raises the nodes' file-watch
limits (`fs.inotify`), which busy nodes run out of.

At the end it shows which nodes need a reboot and asks which to **reboot
now** (`r` for the ones that need it, `a`, numbers, or blank for later).
Each is drained, rebooted, waited for until it is Ready again (and its etcd
healthy, for a control plane), and uncordoned before the next one starts.
The node running the update goes last.

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

### The menu

Both modes group the menu into tabs: **Command Center**, **Cluster**,
**VPN**, **Update**, **Remote Join** and **Bootstrappers**. **←/→**, **Tab**,
the number keys **1-6** or a click switch tabs; **↑/↓** and **Enter** pick an
item. In node mode, **D** switches between SAFE-DRY-RUN and LIVE from any tab.

The Command Center tab has the tools:

| Item | What it does |
|---|---|
| Command Center | Live view of the whole cluster (below) |
| Files | Two-pane file manager across this computer, every node and every Longhorn volume (below) |
| SSH Console | A shell on any node; **K** installs this machine's key on a node once, so later logins need no password. Opens instantly with the node list the activity lights already have, then refreshes |
| Trust Cluster Certificates | (workstation) Lists the cluster's own certificate authorities (cert-manager CA issuers: the Homelab Root CA, Rancher's, any you add) with fingerprints and whether this computer trusts them. **T** trusts the selected or marked ones (**Space**), **A** all, **R** removes; on Windows they go into your user's trusted roots (Windows asks to confirm, no admin needed), on Linux the system CAs (sudo), on macOS the login keychain. **S** saves them as `.crt` files in Downloads for phones |
| Transfer Files to a Node | (workstation) Copy files or folders from this computer to a node (below) |
| Open Shell on Control Plane, Open k9s | (workstation) A terminal on the control plane; k9s on this computer |
| Share KubesTUI with a Workstation | (node mode) Sets up workstation mode on another computer |

### Files

A two-pane file manager, like superfile or Midnight Commander, across
**this computer and every node**. Each pane shows one device; the active
pane has the bright border.

| Key | Action |
|---|---|
| Tab / click | Switch pane |
| **o**, **[ ]**, click the device name | Change the pane's device: **o** opens the list (with status lights), **[** / **]** step to the previous/next device |
| Enter / → | Open a folder, preview a file |
| ← / Backspace | Up a folder |
| Space / Ctrl+A | Mark / mark all |
| **c** (F5) / **m** (F6) | Copy / move the marked items (or the one under the cursor) into the other pane's folder |
| r (F2) / n (F7) / d (F8, Del) | Rename / new folder / delete |
| / / ? / g / ~ | Filter / search below / go to a path / home |
| i / . / Ctrl+R | Size of the selection / hidden files / reload |
| Esc / q | Clear the filter or search, then back to the menu |

Copy and move take the fastest route:

| From → to | How |
|---|---|
| into / out of a Longhorn volume | A tar stream through the volume's helper pod (`kubectl exec`) |
| node → another node | Straight between the two nodes with two Kubernetes Jobs: a receiver on the destination (`nc -l \| tar -x`) and a sender on the source (`tar -c \| nc`), in the `kubestui` namespace. The data never goes through your computer; the Jobs are removed afterwards |
| within one node | `cp -a` / `mv` on the node |
| this computer ↔ node | tar over SSH |
| hosts that aren't cluster nodes | relayed through KubesTUI |

**Longhorn volumes.** The device list (**o**) also has a **Longhorn
volumes** section: every volume with its size, the node it's attached to
and the app using it. Open one in a pane and it works like any other
device: browse, preview, rename, delete, and copy files into or out of it.
This is how to give a converted Docker Compose app its old config: put the
old config folder (on this computer or a node) in one pane, the app's
volume in the other, and copy. In the Command Center, **F** in the storage
panel opens Files with the selected volume already in the right pane.

- A volume isn't a folder on a node's disk, so opening one starts a small
  helper pod that mounts it at `/data`, on the node it's attached to
  (which works while the app is running). The pane can't go above `/data`.
  The pod is removed when you switch away or close Files (and after 4
  hours at the latest).
- Files copied into a volume get the owner of the folder they land in
  (e.g. `1000:1000` for linuxserver images), so the app can write to them.
- Then it offers to restart the app using the volume, so it picks the
  files up (`kubectl rollout restart`).

Safety: system folders (`/etc`, `/usr`, `/boot`, `/var/lib/kubelet`,
`/var/lib/containerd`, `/var/lib/etcd`, `/var/lib/longhorn`, ...) can be
browsed but not changed, and top-level folders like `/home` can't be
renamed or deleted. Deletes ask first, copies warn about files they would
overwrite, a move deletes the originals only after the copy worked, and
every change is logged to `~/.kubestui/files.log`. Folders the SSH user
can't read or write use `sudo` when the node allows it without a password.
Nodes are reached with the same SSH logins as the SSH Console.

### Transfer Files to a Node

(Workstation.) Copies files or folders from this computer to a node: a
folder arrives with everything inside it.

- **File or folder:** drag them from Explorer into the box (Windows Terminal
  and PowerShell drops both work), type a path, or use **Browse files…** /
  **Browse folder…** for the Windows dialogs (handy when the terminal
  refuses drops, e.g. when it runs as administrator). Under WSL, `C:\...`
  paths work too.
- **Node:** every node with a green (on) or red (off) light. The SSH user
  follows the node: the one saved in the SSH Console, or the node's name
  when your users are named after their nodes.
- **Folder on the node:** defaults to `/home/<user>/`; it's created if
  missing. If it needs root, it asks to use sudo.

Every kind of file is sent, including OneDrive online-only files; files that
can't be read (in use, no permission) are skipped and listed at the end.

### Command Center

The first item in the menu (both modes): a live, btop-style view of the whole
cluster that refreshes every 2 seconds.

| Panel | Shows |
|---|---|
| 1 cluster | API health and latency, VIP/API address, Kubernetes version, node/pod/workload/app totals, and CPU, memory and network graphs |
| 2 nodes | Every node: IP, role, CPU and memory meters with history, disk, network ↓↑, pods, status (a powered-off node shows *unreachable* within seconds) |
| 3 pods | All pods, like btop's process list: namespace, node, ready, restarts, CPU, memory, status |
| 4 namespaces | Pods and usage per namespace; Enter shows only that namespace's pods |
| 5 apps | Argo CD applications: sync and health |
| 6 network | MetalLB LAN IPs (and pool usage) and ingress hostnames |
| 7 storage | Longhorn disk space per node, volumes and their health, the node running each one's app (NODE) and the nodes holding its copies (COPIES, yellow when all on one node), other claims |
| 8 alerts | What needs attention (down nodes, crashing pods, degraded apps or volumes, volumes with every copy on one node, full disks, expiring certificates), then recent warning events |

| Key | Action |
|---|---|
| 1-8 / Tab / mouse | Pick a panel (narrow terminals show some as tabs; ←/→ switches) |
| ↑↓ PgUp PgDn / wheel | Select |
| Enter / double-click | Details (live): node, pod, app, IP, volume, alert |
| / | Search pods (Enter keeps the filter, Esc clears it) |
| S / R | Sort (CPU, memory, restarts, age, name, status) / reverse |
| Z | Zoom the panel to full screen |
| L | Logs of the selected pod (C next container, P previous run) |
| X | Restart (delete) the selected pod; its controller starts a new one |
| C | Cordon or uncordon the selected node |
| F | (storage panel) Files on the selected Longhorn volume |
| E | (storage panel) Change App Storage |
| B | (storage panel) Spread Storage Across Nodes |
| + / - | Refresh faster or slower (1s to 30s); P pauses |
| Esc | Close details, clear filters, then back to the menu |

It reads the Kubernetes API directly: with `admin.conf` on a control plane,
and with the workstation's own credential (through the built-in VPN when
away). Usage needs metrics-server, disk and network come from the kubelet,
and the apps and storage panels need Argo CD and Longhorn. Restart and cordon
ask first, and in node mode only work in LIVE mode. Workers have no cluster
access, so open it on a control plane or a workstation.

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
  ai/             hermes
bootstrap/        Argo CD values and ingress, the root app, the default project
config/           settings (see above)
templates/        Helm values templates (Cilium)
generated/        files created at runtime (kubeadm config, join scripts, package)
```

The `monitoring`, `databases` and `ai` app groups exist but are still empty.
