#!/usr/bin/env bash

# Copyright 2014 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Bring up a Kubernetes cluster.
# Usage:
#   wget -q -O - https://get.k8s.io | bash
# or
#   curl -fsSL https://get.k8s.io | bash
#
# Advanced options
#  Set KUBERNETES_PROVIDER to choose between different providers:
#  Google Compute Engine [default]
#   * export KUBERNETES_PROVIDER=gce; wget -q -O - https://get.k8s.io | bash
   unset KUBERNETES_PROVIDER
#  Set KUBERNETES_RELEASE to choose a specific release instead of the current
#    stable release, (e.g. 'v1.3.7').
#    See https://github.com/kubernetes/kubernetes/releases for release options.
#  Set KUBERNETES_RELEASE_URL to choose where to download binaries from.
#    (Defaults to https://storage.googleapis.com/kubernetes-release/release).
#
#  Set KUBERNETES_SERVER_ARCH to choose the server (Kubernetes cluster)
#  architecture to download:
#    * amd64 [default]
#    * arm
#    * arm64
   export KUBERNETES_SERVER_ARCH=s390x

#  Set KUBERNETES_NODE_PLATFORM to choose the platform for which to download
#  the node binaries. If none of KUBERNETES_NODE_PLATFORM and
#  KUBERNETES_NODE_ARCH is set, no node binaries will be downloaded. If only
#  one of the two is set, the other will be defaulted to the
#  KUBERNETES_SERVER_PLATFORM/ARCH.
#    * linux
#    * windows
#
#  Set KUBERNETES_NODE_ARCH to choose the node architecture to download the
#  node binaries. If none of KUBERNETES_NODE_PLATFORM and
#  KUBERNETES_NODE_ARCH is set, no node binaries will be downloaded. If only
#  one of the two is set, the other will be defaulted to the
#  KUBERNETES_SERVER_PLATFORM/ARCH.
#    * amd64 [default]
#    * arm
#    * arm64
#
#  Set KUBERNETES_SKIP_DOWNLOAD to skip downloading a release.
#  Set KUBERNETES_SKIP_CONFIRM to skip the installation confirmation prompt.
#  Set KUBERNETES_SKIP_CREATE_CLUSTER to skip starting a cluster.
#  Set KUBERNETES_SKIP_RELEASE_VALIDATION to skip trying to validate the
#      Kubernetes release string. This implies that you know what you're doing
#      and have set KUBERNETES_RELEASE and KUBERNETES_RELEASE_URL properly.

#export KUBERNETES_SKIP_CREATE_CLUSTER=true
export KUBERNETES_SKIP_CONFIRM=true
set -o errexit
set -o nounset
set -o pipefail

# If KUBERNETES_RELEASE_URL is overridden but KUBERNETES_CI_RELEASE_URL is not then set KUBERNETES_CI_RELEASE_URL to KUBERNETES_RELEASE_URL.
KUBERNETES_CI_RELEASE_URL="${KUBERNETES_CI_RELEASE_URL:-${KUBERNETES_RELEASE_URL:-https://dl.k8s.io/ci}}"
KUBERNETES_RELEASE_URL="${KUBERNETES_RELEASE_URL:-https://dl.k8s.io}"

KUBE_RELEASE_VERSION_REGEX="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-([a-zA-Z0-9]+)\\.(0|[1-9][0-9]*))?$"
KUBE_CI_VERSION_REGEX="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)-([a-zA-Z0-9]+)\\.(0|[1-9][0-9]*)(\\.(0|[1-9][0-9]*)\\+[-0-9a-z]*)?$"

# Sets KUBE_VERSION variable if an explicit version number was provided (e.g. "v1.0.6",
# "v1.2.0-alpha.1.881+376438b69c7612") or resolves the "published" version
# <path>/<version> (e.g. "release/stable",' "ci/latest-1") by reading from GCS.
#
# See the docs on getting builds for more information about version
# publication.
#
# Args:
#   $1 version string from command line
# Vars set:
#   KUBE_VERSION
function set_binary_version() {
  if [[ "${1}" =~ "/" ]]; then
    KUBE_VERSION=$(curl -fsSL --retry 5 "https://dl.k8s.io/${1}.txt")
  else
    KUBE_VERSION=${1}
  fi
  export KUBE_VERSION
}

# Use the script from inside the Kubernetes tarball to fetch the client and
# server binaries (if not included in kubernetes.tar.gz).
function download_kube_binaries {
  (
    cd kubernetes
    if [[ -x ./cluster/get-kube-binaries.sh ]]; then
      # comment out gcloud commnd
      sed -i 's/curl_headers="Authorization/#curl_headers="Authorization/' ./cluster/get-kube-binaries.sh
      sed -i '/#curl_headers="/i \\techo "inide if"' ./cluster/get-kube-binaries.sh
      # Make sure to use the same download URL in get-kube-binaries.sh
      KUBERNETES_RELEASE_URL="${KUBERNETES_RELEASE_URL}" \
        ./cluster/get-kube-binaries.sh
    fi
  )
}

function setUpKubelet {
        mkdir -p /opt/cni/bin
    wget https://github.com/containernetworking/plugins/releases/download/v0.8.6/cni-plugins-linux-s390x-v0.8.6.tgz
    tar -xvf cni-plugins-linux-s390x-v0.8.6.tgz -C /opt/cni/bin --strip-components 1

        mkdir -p /etc/systemd/system/kubelet.service.d/
cat <<EOF >>/etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStartPre=/bin/mkdir -p /etc/kubernetes/manifests
ExecStart=/usr/bin/kubelet \
--v=4
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >>/etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF
        systemctl enable kubelet.service
}

function create_cluster {
  if [[ -n "${KUBERNETES_SKIP_CREATE_CLUSTER-}" ]]; then
    exit 0
  fi
  echo "Creating a kubernetes on Host ..."
  (
    #Extract server binaries
    mkdir -p ${PWD}/k8s_server
    tar -xzf ${PWD}/kubernetes/server/kubernetes-server-linux-s390x.tar.gz -C ${PWD}/k8s_server --strip-components 1
    export PATH=${PWD}/k8s_server/server/bin:$PATH

    ln -sf ${PWD}/k8s_server/server/bin/kubelet /usr/bin/kubelet
    cd kubernetes
    #    ./cluster/kube-up.sh
#    ./cluster/kubeadm.sh
    if command -v "docker" >/dev/null; then
        echo "docker is found in path ...."
    else
           echo "docker is not found in path ...."
           exit 127
    fi
    echo "Kubernetes binaries at ${PWD}/cluster/"
    export PATH=${PWD}/k8s_server/server/bin:$PATH

    swapoff -a
    setUpKubelet
    export DOCKER_API_VERSION=1.39
    kubeadm init --pod-network-cidr=10.244.0.0/16
    sleep 2m
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    kubectl taint nodes --all node-role.kubernetes.io/master-
    kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
    if [[ ":$PATH:" != *":${PWD}/cluster:"* ]]; then
      echo "You may want to add this directory to your PATH in \$HOME/.profile"
    fi

    echo "Installation successful!"
  )
}

function valid-storage-scope {
  curl "${GCE_METADATA_INTERNAL}/service-accounts/default/scopes" -H "Metadata-Flavor: Google" -s | grep -E "auth/devstorage|auth/cloud-platform"
}

if [[ -n "${KUBERNETES_SKIP_DOWNLOAD-}" ]]; then
  create_cluster
  exit 0
fi

if [[ -d "./kubernetes" ]]; then
  if [[ -z "${KUBERNETES_SKIP_CONFIRM-}" ]]; then
    echo "'kubernetes' directory already exist. Should we skip download step and start to create cluster based on it? [Y]/n"
    read -r confirm
    if [[ ! "${confirm}" =~ ^[nN]$ ]]; then
      echo "Skipping download step."
      create_cluster
      exit 0
    fi
  fi
fi

# TODO: remove client checks once kubernetes.tar.gz no longer includes client
# binaries by default.
kernel=$(uname -s)
case "${kernel}" in
  Darwin)
    ;;
  Linux)
    ;;
  *)
    echo "Unknown, unsupported platform: ${kernel}." >&2
    echo "Supported platforms: Linux, Darwin." >&2
    echo "Bailing out." >&2
    exit 2
esac

machine=$(uname -m)
case "${machine}" in
  x86_64*|i?86_64*|amd64*)
    ;;
  aarch64*|arm64*)
    ;;
  arm*)
    ;;
  s390x*)
    ;;
  i?86*)
    ;;
  *)
    echo "Unknown, unsupported architecture (${machine})." >&2
    echo "Supported architectures x86_64, i686, arm, arm64, s390x" >&2
    echo "Bailing out." >&2
    exit 3
    ;;
esac

file=kubernetes.tar.gz
release=${KUBERNETES_RELEASE:-"release/stable"}

# check for cmd line k8s version
if [[ "$#" -ne 1 && "$#" -eq 0 ]]; then
        set_binary_version "${release}"
else
        set_binary_version $1
fi

# Validate Kubernetes release version.
# Translate a published version <bucket>/<version> (e.g. "release/stable") to version number.
if [[ -z "${KUBERNETES_SKIP_RELEASE_VALIDATION-}" ]]; then
  if [[ ${KUBE_VERSION} =~ ${KUBE_RELEASE_VERSION_REGEX} ]]; then
    # Use KUBERNETES_RELEASE_URL for Releases and Pre-Releases
    # ie. 1.18.0 or 1.19.0-beta.0
    KUBERNETES_RELEASE_URL="${KUBERNETES_RELEASE_URL}"
  elif [[ ${KUBE_VERSION} =~ ${KUBE_CI_VERSION_REGEX} ]]; then
    # Override KUBERNETES_RELEASE_URL to point to the CI bucket;
    # this will be used by get-kube-binaries.sh.
    # ie. v1.19.0-beta.0.318+b618411f1edb98
    KUBERNETES_RELEASE_URL="${KUBERNETES_CI_RELEASE_URL}"
  else
    echo "Version doesn't match regexp" >&2
    exit 1
  fi
fi
kubernetes_tar_url="${KUBERNETES_RELEASE_URL}/${KUBE_VERSION}/${file}"

need_download=true
if [[ -r "${PWD}/${file}" ]]; then
  downloaded_version=$(tar -xzOf "${PWD}/${file}" kubernetes/version 2>/dev/null || true)
  echo "Found preexisting ${file}, release ${downloaded_version}"
  if [[ "${downloaded_version}" == "${KUBE_VERSION}" ]]; then
    echo "Using preexisting kubernetes.tar.gz"
    need_download=false
  fi
fi

if "${need_download}"; then
  echo "Downloading kubernetes release ${KUBE_VERSION}"
  echo "  from ${kubernetes_tar_url}"
  echo "  to ${PWD}/${file}"
fi

if [[ -e "${PWD}/kubernetes" ]]; then
  # Let's try not to accidentally nuke something that isn't a kubernetes
  # release dir.
  if [[ ! -f "${PWD}/kubernetes/version" ]]; then
    echo "${PWD}/kubernetes exists but does not look like a Kubernetes release."
    echo "Aborting!"
    exit 5
  fi
  echo "Will also delete preexisting 'kubernetes' directory."
fi

if [[ -z "${KUBERNETES_SKIP_CONFIRM-}" ]]; then
  echo "Is this ok? [Y]/n"
  read -r confirm
  if [[ "${confirm}" =~ ^[nN]$ ]]; then
    echo "Aborting."
    exit 0
  fi
fi

if "${need_download}"; then
  if [[ $(which curl) ]]; then
    # if the url belongs to GCS API we should use oauth2_token in the headers
    curl_headers=""
    #if { [[ "${KUBERNETES_PROVIDER:-gce}" == "gce" ]] || [[ "${KUBERNETES_PROVIDER}" == "gke" ]] ; } &&
    #   [[ "$kubernetes_tar_url" =~ ^https://storage.googleapis.com.* ]] ; then
    #  curl_headers="Authorization: Bearer $(gcloud auth print-access-token)"
    #fi
    curl ${curl_headers:+-H "${curl_headers}"} -fL --retry 3 --keepalive-time 2 "${kubernetes_tar_url}" -o "${file}"
  elif [[ $(which wget) ]]; then
   wget "${kubernetes_tar_url}"
  else
    echo "Couldn't find curl or wget.  Bailing out."
    exit 1
  fi
fi

echo "Unpacking kubernetes release ${KUBE_VERSION}"
rm -rf "${PWD}/kubernetes"
tar -xzf ${file}


download_kube_binaries
create_cluster
