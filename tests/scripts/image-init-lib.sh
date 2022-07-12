#!/usr/bin/env bash
[ -z "$TESTDIR" ] && TESTDIR=$(realpath $(dirname "$0")/../)

SUDO="sudo"

declare -A MNTS=()
declare -A DEVS=()

perror() {
       echo $@>&2
}

perror_exit() {
       echo $@>&2
       exit 1
}

is_mounted()
{
       findmnt -k -n $1 &>/dev/null
}

is_qemu_image_locked()
{
	qemu-img info $1 2>&1 >/dev/null | grep -q "lock"
}

# call guestmount and wait for image is truely umounted.
#
# guestumount simply asks qemu to quit. When guesumount returns, qemu may still
# in the quiting process. In this case, if we start a new qemu instance, it will
# complain with 'Failed to get shared "write" lock'.
sync_guestunmount() {
	local i _image _mnt _wait_times

	DEFAULT_TIMES=100
	_image=$1
	_mnt=$2
	i=0

	$SUDO LIBGUESTFS_BACKEND=direct guestunmount $_mnt

	if [[ $GUEST_UNMOUNT_WAIT_TIMES ]]; then
		_wait_times=$GUEST_UNMOUNT_WAIT_TIMES
	else
		_wait_times=$DEFAULT_TIMES
	fi

	# wait 10s at maximum for $_image to be available
	while is_qemu_image_locked $_image && [[ $i -lt $_wait_times ]]; do
		i=$[$i+1]
		sleep 0.1
	done

	if [[ $i == $_wait_times ]]; then
		perror_exit "After 0.1*$_wait_times seconds, $_image is still locked. You may need to increase GUEST_UNMOUNT_WAIT_TIMES (default=$DEFAULT_TIMES)"
	fi
}

clean_up()
{
	for _image in ${!MNTS[@]}; do
		_mnt=${MNTS[$_image]}
		if [[ $USE_GUESTMOUNT ]] && is_mounted $_mnt; then
			sync_guestunmount $_image $_mnt
		else
			is_mounted $_mnt && $SUDO umount -f -R $_mnt
		fi
		rm $_image.lock
	done

	if [[ ! $USE_GUESTMOUNT ]]; then
		for _dev in ${DEVS[@]}; do
			[ ! -e "$_dev" ] && continue
			[[ "$_dev" == "/dev/loop"* ]] && $SUDO losetup -d "$_dev"
			[[ "$_dev" == "/dev/nbd"* ]] && $SUDO qemu-nbd --disconnect "$_dev"
		done
	fi

	[ -d "$TMPDIR" ] && $SUDO rm --one-file-system -rf -- "$TMPDIR";
	sync
}

trap '
ret=$?;
clean_up
exit $ret;
' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

readonly TMPDIR="$(mktemp -d -t kexec-kdump-test.XXXXXX)"
[ -d "$TMPDIR" ] || perror_exit "mktemp failed."

get_image_fmt() {
	local image=$1 fmt

	[ ! -e "$image" ] && perror "image: $image doesn't exist" && return 1

	fmt=$(qemu-img info $image | sed -n "s/file format:\s*\(.*\)/\1/p")

	[ $? -eq 0 ] && echo $fmt && return 0

	return 1
}

fmt_is_qcow2() {
	[ "$1" == "qcow2" ] || [ "$1" == "qcow2 backing qcow2" ]
}

# If it's partitioned, return the mountable partition, else return the dev
get_mountable_dev() {
	local dev=$1 parts

	$SUDO partprobe $dev && sync
	parts="$(ls -1 ${dev}p*)"
	if [ -n "$parts" ]; then
		if [ $(echo "$parts" | wc -l) -gt 1 ]; then
			perror "It's a image with multiple partitions, using last partition as main partition"
		fi
		echo "$parts" | tail -1
	else
		echo "$dev"
	fi
}

# get the separate boot partition
# return the 2nd partition as boot partition
get_mount_boot() {
	local dev=$1 _second_part=${dev}p2

	if [[ $(lsblk -f $_second_part -n -o LABEL 2> /dev/null) == boot ]]; then
		echo $_second_part
	fi
}


prepare_loop() {
	[ -n "$(lsmod | grep "^loop")" ] && return

	$SUDO modprobe loop

	[ ! -e "/dev/loop-control" ] && perror_exit "failed to load loop driver"
}

prepare_nbd() {
	[ -n "$(lsmod | grep "^nbd")" ] && return

	$SUDO modprobe nbd max_part=4

	[ ! -e "/dev/nbd0" ] && perror_exit "failed to load nbd driver"
}

mount_nbd() {
	local image=$1 size dev
	for _dev in /sys/class/block/nbd* ; do
		size=$(cat $_dev/size)
		if [ "$size" -eq 0 ] ; then
			dev=/dev/${_dev##*/}
			$SUDO qemu-nbd --connect=$dev $image 1>&2
			[ $? -eq 0 ] && echo $dev && break
		fi
	done

	return 1
}

image_lock()
{
	local image=$1 timeout=5 fd

	eval "exec {fd}>$image.lock"
	if [ $? -ne 0 ]; then
		perror_exit "failed acquiring image lock"
		exit 1
	fi

	flock -n $fd
	rc=$?
	while [ $rc -ne 0 ]; do
		echo "Another instance is holding the image lock ..."
		flock -w $timeout $fd
		rc=$?
	done
}

# Mount a device, will umount it automatially when shell exits
mount_image() {
	local image=$1 fmt
	local dev mnt mnt_dev boot root

	# Lock the image just in case user run this script in parrel
	image_lock $image

	fmt=$(get_image_fmt $image)
	[ $? -ne 0 ] || [ -z "$fmt" ] && perror_exit "failed to detect image format"

	if [ "$fmt" == "raw" ]; then
		prepare_loop

		dev="$($SUDO losetup --show -f $image)"
		[ $? -ne 0 ] || [ -z "$dev" ] && perror_exit "failed to setup loop device"

	elif fmt_is_qcow2 "$fmt"; then
		if [[ ! $USE_GUESTMOUNT ]]; then
			prepare_nbd
			dev=$(mount_nbd $image)
			[ $? -ne 0 ] || [ -z "$dev" ] perror_exit "failed to connect qemu to nbd device '$dev'"
		fi
	else
		perror_exit "Unrecognized image format '$fmt'"
	fi
	DEVS[$image]="$dev"

	mnt="$(mktemp -d -p $TMPDIR -t mount.XXXXXX)"
	[ $? -ne 0 ] || [ -z "$mnt" ] && perror_exit "failed to create tmp mount dir"
	MNTS[$image]="$mnt"

	if [[ $USE_GUESTMOUNT ]]; then
		$SUDO LIBGUESTFS_BACKEND=direct guestmount -a $image -i $mnt
	else
		mnt_dev=$(get_mountable_dev "$dev")
		[ $? -ne 0 ] || [ -z "$mnt_dev" ] && perror_exit "failed to setup loop device"
		$SUDO mount $mnt_dev $mnt
		[ $? -ne 0 ] && perror_exit "failed to mount device '$mnt_dev'"
		boot=$(get_mount_boot "$dev")
		if [[ -n "$boot" ]]; then
			root=$(get_image_mount_root $image)
			$SUDO mount $boot $root/boot
			[ $? -ne 0 ] && perror_exit "failed to mount the bootable partition for device '$mnt_dev'"
		fi
	fi
}

get_image_mount_root() {
	local image=$1
	local root=${MNTS[$image]}

	# Starting from Fedora 36, the root node is /root/root of the last partition
	[ -d "$root/root/root" ] && root=$root/root
	echo $root

	if [ -z "$root" ]; then
		return 1
	fi
}

shell_in_image() {
	local root=$(get_image_mount_root $1) && shift

	pushd $root

	$SHELL

	popd
}

inst_pkg_in_image() {
	local root=$(get_image_mount_root $1) && shift

	# LSB not available
	# release_info=$($SUDO chroot $root /bin/bash -c "lsb_release -a")
	# release=$(echo "$release_info" | sed -n "s/Release:\s*\(.*\)/\1/p")
	# distro=$(echo "$release_info" | sed -n "s/Distributor ID:\s*\(.*\)/\1/p")
	# if [ "$distro" != "Fedora" ]; then
	# 	perror_exit "only Fedora image is supported"
	# fi
	release=$(sudo cat $root/etc/fedora-release | sed -n "s/.*[Rr]elease\s*\([0-9]*\).*/\1/p")
	[ $? -ne 0 ] || [ -z "$release" ] && perror_exit "only Fedora image is supported"

	$SUDO dnf --releasever=$release --installroot=$root install -y $@
}

run_in_image() {
	local root=$(get_image_mount_root $1) && shift

	$SUDO chroot $root /bin/bash -c "$@"
}

inst_in_image() {
	local image=$1 src=$2 dst=$3
	local root=$(get_image_mount_root $1)

	$SUDO cp $src $root/$dst
}

# If source image is qcow2, create a snapshot
# If source image is raw, convert to raw
# If source image is xz, decompress then repeat the above logic
#
# Won't touch source image
create_image_from_base_image() {
	local image=$1
	local output=$2
	local decompressed_image

	local ext="${image##*.}"
	if [[ "$ext" == 'xz' ]]; then
		echo "Decompressing base image..."
		xz -d -k $image
		decompressed_image=${image%.xz}
		image=$decompressed_image
	fi

	local image_fmt=$(get_image_fmt $image)
	if [ "$image_fmt" != "raw" ]; then
		if fmt_is_qcow2 "$image_fmt"; then
			echo "Source image is qcow2, using snapshot..."
			qemu-img create -f qcow2 -b $image -F qcow2 $output
		else
			perror_exit "Unrecognized base image format '$image_mnt'"
		fi
	else
		echo "Source image is raw, converting to qcow2..."
		qemu-img convert -f raw -O qcow2 $image $output
	fi

	# Clean up decompress temp image
	if [ -n "$decompressed_image" ]; then
		rm $decompressed_image
	fi
}
