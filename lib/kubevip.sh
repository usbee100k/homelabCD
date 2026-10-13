#!/usr/bin/env bash

# install_kubevip [VERSION]
# Writes the kube-vip static pod that holds the control-plane VIP.
# Without VERSION, the latest release is used.
install_kubevip() {

    log_info "Installing kube-vip..."

    mkdir -p /etc/kubernetes/manifests

    KUBEVIP_VERSION="${1:-}"

    if [[ -z "${KUBEVIP_VERSION}" ]]; then
        KUBEVIP_VERSION=$(curl -s https://api.github.com/repos/kube-vip/kube-vip/releases/latest | jq -r .tag_name)
    fi

    ctr image pull ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}

    ctr run \
        --rm \
        --net-host \
        ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION} \
        vip /kube-vip manifest pod \
        --interface "${DEFAULT_INTERFACE}" \
        --address "${VIP_ADDRESS}" \
        --controlplane \
        --arp \
        --leaderElection \
        >/etc/kubernetes/manifests/kube-vip.yaml

    log_ok "kube-vip configured."

}

# join_kubevip
# Runs kube-vip on a joined control plane too, so the VIP moves to this
# node if the one holding it goes down. Uses the version already running
# in the cluster, so every control plane runs the same kube-vip.
join_kubevip() {

    local image version

    local i
    image=""

    # The API can be briefly unavailable right after a join while etcd
    # adds the new member, so retry. Not finding it is not fatal.
    for i in {1..12}; do
        image="$(kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
            | grep -m1 'kube-vip/kube-vip:' || true)"
        [[ -n "${image}" ]] && break
        sleep 5
    done

    version="${image##*:}"

    if [[ -z "${image}" || -z "${version}" ]]; then
        log_warn "kube-vip version in the cluster not found; using the latest release."
        version=""
    fi

    install_kubevip "${version}"

}

# ensure_kubevip_all_controlplanes
# Control planes joined before join_kubevip existed have no kube-vip. Run
# from a control plane that has it (the bootstrap node), this copies its
# kube-vip manifest to every control plane without a kube-vip pod, through
# a short Job on that node, with the node's own network interface.
ensure_kubevip_all_controlplanes() {

    local manifest="/etc/kubernetes/manifests/kube-vip.yaml"
    local ns="kube-system"
    local node have missing=()

    [[ -f "${manifest}" ]] || return 0
    command -v kubectl >/dev/null 2>&1 || return 0
    kubectl get nodes >/dev/null 2>&1 || return 0

    have="$(kubectl -n "${ns}" get pods \
        -o jsonpath='{range .items[*]}{.spec.nodeName} {.spec.containers[0].image}{"\n"}{end}' \
        | awk '$2 ~ /kube-vip\/kube-vip:/ {print $1}')"

    while read -r node; do
        [[ -n "${node}" ]] || continue
        grep -qx "${node}" <<<"${have}" || missing+=("${node}")
    done < <(kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    if (( ${#missing[@]} == 0 )); then
        log_ok "kube-vip runs on every control plane."
        return 0
    fi

    log_info "Adding kube-vip to control planes without it: ${missing[*]}"

    kubectl -n "${ns}" create configmap homelabcd-kube-vip \
        --from-file=kube-vip.yaml="${manifest}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    local failed=0

    for node in "${missing[@]}"; do

        local job="kube-vip-install-${node}"

        kubectl -n "${ns}" delete job "${job}" --ignore-not-found >/dev/null

        kubectl apply -f - >/dev/null <<YAML || { failed=1; continue; }
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${ns}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300
  template:
    spec:
      nodeName: ${node}
      hostNetwork: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: install
          image: busybox:1.37
          command:
            - /bin/sh
            - -c
            - |
              set -e
              iface="\$(ip route | awk '/^default/ {print \$5; exit}')"
              [ -n "\${iface}" ] || { echo "no default route"; exit 1; }
              # kubelet ignores files starting with a dot
              sed "/name: vip_interface/{n;s/value: .*/value: \${iface}/}" /src/kube-vip.yaml > /manifests/.kube-vip.yaml.tmp
              mv /manifests/.kube-vip.yaml.tmp /manifests/kube-vip.yaml
              echo "kube-vip installed on interface \${iface}"
          volumeMounts:
            - name: src
              mountPath: /src
            - name: manifests
              mountPath: /manifests
      volumes:
        - name: src
          configMap:
            name: homelabcd-kube-vip
        - name: manifests
          hostPath:
            path: /etc/kubernetes/manifests
            type: Directory
YAML

        if kubectl -n "${ns}" wait --for=condition=complete "job/${job}" --timeout=120s >/dev/null 2>&1; then
            log_ok "${node}: $(kubectl -n "${ns}" logs "job/${job}" 2>/dev/null | tail -1)"
        else
            log_warn "${node}: kube-vip install did not finish. Check: kubectl -n ${ns} logs job/${job}"
            failed=1
        fi

    done

    kubectl -n "${ns}" delete configmap homelabcd-kube-vip --ignore-not-found >/dev/null

    return "${failed}"
}
