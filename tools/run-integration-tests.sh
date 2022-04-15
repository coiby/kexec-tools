#!/bin/bash
set -ex

[[ -d ${0%/*} ]] && cd "${0%/*}"/../

source /etc/os-release

cd tests

# fedpkg fetch sources based on branch.f$VERSION_ID.remote
if ! git remote show | grep -q fedora_src; then
	git remote add fedora_src https://src.fedoraproject.org/rpms/kexec-tools.git
	git config --add branch.f$VERSION_ID.remote fedora_src
fi

can_we_use_qemu_nbd()
{
	_tmp_img=/tmp/test.qcow2

	(sudo -v && sudo modprobe nbd \
		&& qemu-img create -fqcow2 $_tmp_img 10m \
		&& qemu-nbd -c /dev/nbd0 $_tmp_img && sudo qemu-nbd -d /dev/nbd0 && rm $_tmp_img) &> /dev/null
}

if ! can_we_use_qemu_nbd; then
	USE_GUESTMOUNT=1
fi

KUMP_TEST_QEMU_TIMEOUT=20m USE_GUESTMOUNT=$USE_GUESTMOUNT BASE_IMAGE=/usr/share/cloud_images/Fedora-Cloud-Base-35-1.2.x86_64.qcow2 RELEASE=$VERSION_ID make test-run
