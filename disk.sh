#! /bin/sh
##
## disk.sh --
##
##   Manipulate disk images. The image must exist and be partitioned.
##   By default 'udisksctl' is used, but will fallback to 'sudo' if
##   environment "DISK_SUDO=yes" is specified
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
test -n "$TEMP" || TEMP=/tmp/tmp/$USER
tmp=$TEMP/${prg}_$$

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}
test -n "$1" || help
echo "$1" | grep -qi "^help\|-h" && help

log() {
	echo "$*" >&2
}
findf() {
	local d
	for d in $(echo $FSEARCH_PATH | tr : ' '); do
		f=$d/$1
		test -r $f && return 0
	done
	unset f
	return 1
}
findar() {
	findf $1.tar.bz2 || findf $1.tar.gz || findf $1.tar.xz || findf $1.tgz || findf $1.zip
}

##   env
##     Print environment.
cmd_env() {
	test "$envread" = "yes" && return 0
	envread=yes
	eset ARCHIVE=$HOME/archive
	eset FSEARCH_PATH=$HOME/Downloads:$ARCHIVE
	eset \
		__image=/tmp/tmp/$USER/hd.img \
		__p=1 \
		DISK_SUDO=no
	if test "$cmd" = "env"; then
		set | grep -E "^($opts)="
		exit 0
	fi
	test -n "$long_opts" && export $long_opts
	test "$DISK_SUDO" = "yes" && postfix=_sudo
}
# Set variables unless already defined
eset() {
	local e k
	for e in $@; do
		k=$(echo $e | cut -d= -f1)
		opts="$opts|$k"
		test -n "$(eval echo \$$k)" || eval $e
		test "$(eval echo \$$k)" = "?" && eval $e
	done
}

# Get partition data
getpart() {
	mkdir -p $tmp
	local o=$tmp/disk
	sfdisk -l -J $__image > $o || die "Can't get partition data [$__image]"
	local v
	v=$(jq .partitiontable.sectorsize < $o)
	test "$v" -eq 512 || die "Invalid sectorsize [$v]"
	sectorsize=$v
	local p=$((__p - 1))
	v=$(jq .partitiontable.partitions[$p].start < $o)
	test "$v" != "null" || die "Can't find 'start' of partition [$__p]"
	pstart=$v
	v=$(jq .partitiontable.partitions[$p].size < $o)
	test "$v" != "null" || die "Can't find 'size' of partition [$__p]"
	psize=$v
}

##   mkimage [--image=] [--edit]
##     Create a "default" image. 128MiB, GPT partitioned with a EFI
##     and a Linux partition. For FAT/NTFS use:
##     EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
cmd_mkimage() {
	mkdir -p $tmp
	local o=$tmp/ptable
	cat > $o <<EOF
label: gpt
,34MiB,U,
,,L,
EOF
	test "$__edit" = "yes" && vi $o
	rm -f $__image
	truncate -s 128MiB $__image || die "Image not writable [$__image]"
	sfdisk --no-tell-kernel --no-reread $__image < $o || die "sfdisk"
}

##   mkfat [--image=] [--p=#] -- [mkfs.fat-options...]
##     Format a partition with a FAT file system
cmd_mkfat() {
	test -r "$__image" || die "Image not readable [$__image]"
	getpart
	mkfs.fat -S $sectorsize --offset $pstart $@ $__image $psize		
}
##   mkext [--image=] [--p=#] -- [mke2fs-options...]
##     Format a partition with an EXT (Linux) file system. Example:
##     mkext --p=2 -- -t ext3
cmd_mkext() {
	test -r "$__image" || die "Image not readable [$__image]"
	getpart
	local offset=$((pstart * sectorsize))
	local fssize=$((psize * sectorsize / 1024))
	mke2fs -E offset=$offset $__image $fssize
}
##   loop-setup [--image=]
##     Loopback-mount the image. Prints the device if succesful
cmd_loop_setup() {
	test -r "$__image" || die "Image not readable [$__image]"
	loop_setup$postfix
}
loop_setup() {
	mkdir -p $tmp
	local o=$tmp/dev
	udisksctl loop-setup -f $__image > $o || die "udisksctl loop-setup"
	cat $o | grep -E -o '/dev/loop[0-9]+'
}
loop_setup_sudo() {
	sudo losetup -P --show -f $__image
}
##   loop-delete --dev=dev
##     Remove a loopback mount. The dev is taken from the loop-setup printout
cmd_loop_delete() {
	test -n "$__dev" || die "No dev"
	grep -q $__dev /proc/mounts && die "Dev is mounted [$__dev]"
	loop_delete$postfix
}
loop_delete() {
	udisksctl loop-delete -b $__dev
}
loop_delete_sudo() {
	sudo losetup -d $__dev
}
##   mount [--p=#] --dev=dev
##     Mount a partition. The dev is taken from the loop-setup printout.
##     The mount directory is printed on success
cmd_mount() {
	test -n "$__dev" || die "No dev"
	_mount$postfix
}
_mount() {
	local dev=${__dev}p$__p
	test $__p -eq 0 && dev=$__dev
	mkdir -p $tmp
	local o=$tmp/mpoint
	udisksctl mount -b $dev $@ > $o || die "udisksctl mount"
	cat $o | grep -E -o '/media/.*'
}
_mount_sudo() {
	local mnt=$TEMP/media/mnt_$$
	mkdir -p $mnt
	local dev=${__dev}p$__p
	test $__p -eq 0 && dev=$__dev
	if ! sudo mount $dev $mnt; then
		rm -rf $mnt
		die "mount"
	fi
	echo $mnt
}
##   unmount [--p=#] --dev=dev
##     Unmount a partition. The dev is taken from the loop-setup printout.
cmd_unmount() {
	test -n "$__dev" || die "No dev"
	unmount$postfix
}
unmount() {
	local dev=${__dev}p$__p
	test $__p -eq 0 && dev=$__dev
	udisksctl unmount -b $dev $@ || die "udisksctl unmount"
}
unmount_sudo() {
	local dev=${__dev}p$__p
	test $__p -eq 0 && dev=$__dev
	grep -q $dev /proc/mounts || die "Not mounted"
	local mnt=$(grep $dev /proc/mounts | cut -d' ' -f2)
	sudo umount $mnt
	rm -rf $mnt
}

##
# Get the command
cmd=$(echo $1 | tr -- - _)
shift
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
	if echo $1 | grep -q =; then
		o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
		v=$(echo "$1" | cut -d= -f2-)
		eval "$o=\"$v\""
	else
		if test "$1" = "--"; then
			shift
			break
		fi
		o=$(echo "$1" | sed -e 's,-,_,g')
		eval "$o=yes"
	fi
	long_opts="$long_opts $o"
	shift
done
unset o v

# Execute command
trap "die Interrupted" INT TERM
cmd_env
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status
