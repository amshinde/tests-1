#!/bin/bash
#
# Copyright (c) 2017-2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

# Currently we will use this repository until this issue is solved
# See https://github.com/kata-containers/packaging/issues/1

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

[ -z "${DEBUG:-}" ] || set -x

cidir=$(dirname "$0")
source "${cidir}/lib.sh"
source "/etc/os-release" || source "/usr/lib/os-release"

latest_build_url="http://jenkins.katacontainers.io/job/kernel-nightly-$(uname -m)/lastSuccessfulBuild/artifact/artifacts"
kernel_dir="/usr/share/kata-containers"

kernel_repo_name="packaging"
kernel_repo_owner="kata-containers"
kernel_repo="github.com/${kernel_repo_owner}/${kernel_repo_name}"
export GOPATH=${GOPATH:-${HOME}/go}
kernel_repo_dir="${GOPATH}/src/${kernel_repo}"
kernel_arch="$(arch)"
readonly tmp_dir="$(mktemp -d -t install-kata-XXXXXXXXXXX)"
packaged_kernel="kata-linux-container"

exit_handler() {
	rm -rf "${tmp_dir}"
}

trap exit_handler EXIT

download_repo() {
	echo "Download and update ${kernel_repo}"
	pushd ${tmp_dir}
	go get -d -u "${kernel_repo}" || true
	popd
}

get_current_kernel_version() {
	kernel_version=$(get_version "assets.kernel.version")
	echo "${kernel_version/v/}"
}

get_kata_config_version() {
	kata_config_version=$(cat "${kernel_repo_dir}/kernel/kata_config_version")
	echo "${kata_config_version}"
}

build_and_install_kernel() {
	# Always build and install the kernel version found locally
	info "Install kernel from sources"
	pushd "${tmp_dir}" >> /dev/null
	"${kernel_repo_dir}/kernel/build-kernel.sh" -v "${kernel_version}" "setup"
	"${kernel_repo_dir}/kernel/build-kernel.sh" -v "${kernel_version}" "build"
	sudo -E PATH="$PATH" "${kernel_repo_dir}/kernel/build-kernel.sh" -v "${kernel_version}" "install"
	popd >> /dev/null
}

# $1 kernel_binary: binary to install could be vmlinux or vmlinuz
install_cached_kernel(){
	local kernel_binary=${1:-}
	[ -z "${kernel_binary}" ] && die "empty binary format"
	info "Installing ${kernel_binary}"
	sudo mkdir -p "${kernel_dir}"
	local kernel_binary_name="${kernel_binary}-${cached_kernel_version}"
	local kernel_binary_path="${kernel_dir}/${kernel_binary_name}"
	sudo -E curl -fL --progress-bar "${latest_build_url}/${kernel_binary_name}" -o "${kernel_binary_path}" || return 1
	kernel_symlink="${kernel_dir}/${kernel_binary}.container"
	info "Installing ${kernel_binary_path} and symlink ${kernel_symlink}"
	sudo -E ln -sf "${kernel_binary_path}" "${kernel_symlink}"
}


install_prebuilt_kernel() {
	info "Install pre-built kernel version"

	for k in "vmlinux" "vmlinuz"; do
		install_cached_kernel "${k}" || return 1
	done

	pushd "${kernel_dir}" >/dev/null
	info "Verify download checksum"
	sudo -E curl -fsOL "${latest_build_url}/sha256sum-kernel" || return 1
	sudo sha256sum -c "sha256sum-kernel" || return 1
	popd >/dev/null
}

cleanup() {
	rm -rf "${tmp_dir}"
}

main() {
	download_repo
	kernel_version="$(get_current_kernel_version)"
	kata_config_version="$(get_kata_config_version)"
	current_kernel_version="${kernel_version}-${kata_config_version}"
	cached_kernel_version=$(curl -sfL "${latest_build_url}/latest") || cached_kernel_version="none"
	info "current kernel : ${current_kernel_version}"
	info "cached kernel  : ${cached_kernel_version}"
	if [ "$cached_kernel_version" == "$current_kernel_version" ] && [ "$kernel_arch" == "x86_64" ]; then
		# If installing kernel fails,
		# then build and install it from sources.
		if ! install_prebuilt_kernel; then
			info "failed to install cached kernel, trying to build from source"
			build_and_install_kernel
		fi

	else
		build_and_install_kernel
	fi
}

main
