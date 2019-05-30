#!/bin/bash
# SPDX-license-identifier: Apache-2.0
##############################################################################
# Copyright (c) 2019 Intel Corporation
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################

set -o pipefail
set -o xtrace
set -o errexit
set -o nounset

source _commons.sh

./prechecks.sh

# Configure SSH keys for ansible communication
rm -f ~/.ssh/id_rsa*
echo -e "\n\n\n" | ssh-keygen -t rsa -N ""
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
chmod og-wx ~/.ssh/authorized_keys

# Install dependencies
swap_dev=$(sed -n -e 's#^/dev/\([0-9a-z]*\).*#dev-\1.swap#p' /proc/swaps)
if [ -n "$swap_dev" ]; then
    sudo systemctl mask "$swap_dev"
fi
sudo swapoff -a
if [ -e /etc/fstab ]; then
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
fi
# shellcheck disable=SC1091
source /etc/os-release || source /usr/lib/os-release
case ${ID,,} in
    rhel|centos|fedora)
        curl -sL https://bootstrap.pypa.io/get-pip.py | sudo python
    ;;
    clear-linux-os)
        sudo swupd bundle-add python3-basic
    ;;
esac
sudo mkdir -p /etc/ansible/
sudo cp ./ansible.cfg /etc/ansible/ansible.cfg
sudo -E pip install ansible==2.7.10
ansible-galaxy install -r ./galaxy-requirements.yml --ignore-errors

# QAT Driver installation
ansible-playbook -vvv -i ./inventory/hosts.ini configure-qat.yml | tee setup-qat.log
./postchecks_qat_driver.sh

# Kubernetes installation
install_k8s

# QAT Plugin installation
install_docker
ansible-playbook -vvv -i ./inventory/hosts.ini configure-qat-envoy.yml | tee setup-qat-envoy.log

# Kata containers configuration
if [[ "${CONTAINER_MANAGER:-docker}" == "crio" ]]; then
    sudo -E pip install PyYAML
    kube_version=$(parse_yaml inventory/group_vars/k8s-cluster.yml "['kube_version']")
    if vercmp "${kube_version#*v}" '<' 1.14; then
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/release-1.13/cluster/addons/runtimeclass/runtimeclass_crd.yaml
        kubectl apply -f kata-qemu.yml
    else
        kubectl apply -f https://raw.githubusercontent.com/clearlinux/cloud-native-setup/master/clr-k8s-examples/8-kata/kata-qemu-runtimeClass.yaml
    fi

    kubectl apply -f https://raw.githubusercontent.com/kata-containers/packaging/master/kata-deploy/kata-rbac.yaml
    kubectl apply -f https://raw.githubusercontent.com/kata-containers/packaging/master/kata-deploy/kata-deploy.yaml
    sudo docker run -d -p 5000:5000 --restart=always --name registry registry:2
    for img in intel-qat-plugin envoy-qat; do
        sudo docker tag "${img}:devel" "localhost:5000/${img}:devel"
        sudo docker push "localhost:5000/${img}:devel"
    done
    kubectl set image daemonset/intel-qat-plugin intel-qat-plugin=localhost:5000/intel-qat-plugin:devel
    attempts=0
    until kubectl rollout status daemonset/intel-qat-plugin  || [ $attempts -eq 60 ]; do
        attempts+=1
        sleep 10
    done
fi
./postchecks_qat_plugin.sh
