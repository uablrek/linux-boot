#! /bin/sh
##
## admin.sh --
##   Admin script for Linux boot tests
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
test -n "$TEMP" || TEMP=/tmp/tmp/$USER
me=$dir/$prg
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
	findf $1.tar.bz2 || findf $1.tar.gz || findf $1.tar.xz || findf $1.zip || findf $1.tgz || findf $1-x86_64.tar.gz
}

##   env
##     Print environment.
cmd_env() {
	test "$envread" = "yes" && return 0
	envread=yes
	eset \
		ver_syslinux=syslinux-6.03 \
		ver_uboot=u-boot-2025.07 \
		ver_grub=grub-2.12
	unset opts
	eset ARCHIVE=$HOME/archive
	eset FSEARCH_PATH=$HOME/Downloads:$ARCHIVE
	eset \
		BOOTLOADER_WORKSPACE=$TEMP/bootloader \
		KERNELDIR=$HOME/tmp/linux \
		kernel='' \
		__arch=x86_64
	eset WS=$BOOTLOADER_WORKSPACE/$__arch
	# Kernel/BusyBox/initrd is delegated to qemu.sh
	export ver_kernel=linux-6.17.8
	eset qemu=$dir/qemu.sh
	eval $($qemu versions --brief)
	export WS
	
	eset __kobj=$WS/obj/$ver_kernel
	if test "$__arch" = "aarch64"; then
		kernel=$__kobj/arch/arm64/boot/Image
		eset \
			__board=qemu_arm64
	else
		kernel=$__kobj/arch/$__arch/boot/bzImage
		eset \
			__board=sandbox
	fi
	eset \
		__uboot_cfg=$dir/config/$__arch/uboot-$__board \
		__ubootobj=$WS/uboot-obj \
		__type=gpt \
		__size=64MiB \
		edk2d=$GOPATH/src/github.com/tianocore/edk2 \
		__bootscr=$dir/config/u-boot.scr
	eset \
		__initrd=$__kobj/initrd.cpio.gz \
		__image=$WS/hd.img \
		kernel=''
	local d=$edk2d/Build/OvmfX64/DEBUG_GCC5/FV
	if test -d $d; then
		eset \
			OVMF_CODE=$d/OVMF_CODE.fd \
			OVMF_VARS=$d/OVMF_VARS.fd
	else
		eset \
			OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd \
			OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
	fi
	if test "$cmd" = "env"; then
		set | grep -E "^($opts)="
		exit 0
	fi
	test -n "$long_opts" && export $long_opts
	mkdir -p $WS
	disk=$dir/disk.sh
	export __image
}
##   versions [--brief]
##     Print used sw versions
cmd_versions() {
	if test "$__brief" = "yes"; then
		set | grep -E 'ver_[a-z0-9]+='
		return 0
	fi
	local k v
	for k in $(set | grep -E 'ver_[a-z0-9]+=' | cut -d= -f1); do
		v=$(eval echo \$$k)
		if findar $v; then
			printf "%-20s (%s)\n" $v $f
		else
			printf "%-20s (archive missing!)\n" $v
		fi
	done
	test -d $__kdir || echo "Kernel not unpacked at [$__kdir]"
}
# Set variables unless already defined
eset() {
	local e k
	for e in $@; do
		k=$(echo $e | cut -d= -f1)
		opts="$opts|$k"
		test -n "$(eval echo \$$k)" || eval $e
	done
}
# cdsrc <version>
# Cd to the source directory. Unpack the archive if necessary.
cdsrc() {
	test -n "$1" || die "cdsrc: no version"
	test "$__clean" = "yes" && rm -rf $WS/$1
	if ! test -d $WS/$1; then
		findar $1 || die "No archive for [$1]"
		if echo $f | grep -qF '.zip'; then
			unzip -d $WS -qq $f || die "Unzip [$f]"
		else
			tar -C $WS -xf $f || die "Unpack [$f]"
		fi
	fi
	if test -d $WS/$1; then
		cd $WS/$1
		return 0
	fi
	# Try dir-name without version
	local d=$(echo $1 | cut -d- -f1)
	cd $WS/$d
}
##   setup
##     Build and setup everything
cmd_setup() {
	test "$__clean" = "yes" && rm -rf $WS
	cmd_setup_$__arch
}
cmd_setup_x86_64() {
	$qemu kernel_build || die kernel_build
	$qemu busybox_build || die busybox_build
	$me initrd_build initrd || die initrd_build
	$me syslinux_build || die syslinux_build
	$me image_build || die image_build
	log "Test: ./admin.sh qemu --uefi"
}
cmd_setup_aarch64() {
	$qemu kernel_build || die kernel_build
	$qemu busybox_build || die busybox_build
	$me initrd_build initrd || die initrd_build
	$me uboot_build || die uboot_build
	$me uboot-image || die uboot-image
	log "Test: ./admin.sh qemu"
}
##   kernel_build [--menuconfig]
##     Build the kernel
cmd_kernel_build() {
	$qemu kernel_build
}
##   busybox_build [--menuconfig]
##     Build BusyBox
cmd_busybox_build() {
	$qemu busybox_build
}
##   initrd_build [--initrd=] [ovls...]
##     Build a ramdisk (cpio archive) with busybox and the passed
##     ovls (a'la xcluster)
cmd_initrd_build() {
	local bb=$WS/$ver_busybox/busybox
	test -x $bb || die "Not executable [$bb]"
	touch $__initrd || die "Can't create [$__initrd]"

	cmd_gen_init_cpio
	gen_init_cpio=$WS/bin/gen_init_cpio
	mkdir -p $tmp
	cat > $tmp/cpio-list <<EOF
dir /dev 755 0 0
nod /dev/console 644 0 0 c 5 1
dir /bin 755 0 0
file /bin/busybox $bb 755 0 0
slink /bin/sh busybox 755 0 0
EOF
	if test -n "$1"; then
		cmd_collect_ovls $tmp/root $@
		cmd_emit_list $tmp/root >> $tmp/cpio-list
	else
		cat >> $tmp/cpio-list <<EOF
dir /etc 755 0 0
file /init $dir/config/init-tiny 755 0 0
EOF
	fi
	rm -f $__initrd
	local uncompressed=$(echo $__initrd | sed -E 's,.[a-z]+$,,')
	local compression=$(echo $__initrd | grep -oE '[a-z]+$')
	case $compression in
		xz)
			$gen_init_cpio $tmp/cpio-list > $uncompressed
			xz -T0 $uncompressed;;
		gz)
			$gen_init_cpio $tmp/cpio-list | gzip -c > $__initrd;;
		bz)
			$gen_init_cpio $tmp/cpio-list | bzip2 -c > $__initrd;;
		*)
			die "Unknown initrd compression [$compression]";;
	esac
}
#   gen_init_cpio
#     Build the kernel gen_init_cpio utility
cmd_gen_init_cpio() {
	local x=$WS/bin/gen_init_cpio
	test -x $x && return 0
	$qemu kernel-unpack
	mkdir -p $(dirname $x)
	eval $($qemu env | grep __kdir)
	local src=$__kdir/usr/gen_init_cpio.c
	test -r $src || die "Not readable [$src]"
	gcc -o $x $src
}
#   collect_ovls <dst> [ovls...]
#     Collect ovls to the <dst> dir
cmd_collect_ovls() {
	test -n "$1" || die "No dest"
	test -e $1 -a ! -d "$1" && die "Not a directory [$1]"
	mkdir -p $1 || die "Failed mkdir [$1]"
	local ovl d=$1
	shift
	for ovl in $@; do
		test -x $ovl/tar || die "Not executable [$ovl/tar]"
		$ovl/tar - | tar -C $d -x || die "Unpack [$ovl]"
	done
}
#   emit_list <src>
#     Emit a gen_init_cpio list built from the passed <src> dir
cmd_emit_list() {
	test -n "$1" || die "No source"
	local x p d=$1
	test -d $d || die "Not a directory [$d]"
	cd $d
	for x in $(find . -mindepth 1 -type d | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "dir $x $p 0 0"
	done
	for x in $(find . -mindepth 1 -type f | cut -c2-); do
		p=$(stat --printf='%a' $d$x)
		echo "file $x $d$x $p 0 0"
	done
}
# Setup a loop device and define $__dev
loop_setup() {
	__dev=$($disk loop-setup)
	test -n "$__dev" || die "loop-setup"
	export __dev
}
# Mount a partition and define $__p and $mnt
pmount() {
	export __p=$1
	mnt=$($disk mount)
	test -n "$mnt" || die "mount partition [$__p]"
}
##   image_build --info
##   image_build [--type=mbr|gpt|fat] [--size=]
##     Create an image
cmd_image_build() {
	if test "$__info" = "yes"; then
		test -r $__image || die "Not readable [$__image]"
		cd $(dirname $__image) || die
		sfdisk -V -l $(basename $__image)
		return
	fi
	test -r $kernel || die "Not readable [$kernel]"	
	test -r $__initrd || die "Not readable [$__initrd]"	
	rm -f $__image
	truncate -s $__size $__image || die "Failed to create [$__image]"
	case "$__type" in
		"fat")
			image_build_fat;;
		"mbr")
			image_build_mbr;;
		"gpt")
			image_build_gpt;;
		*)
			die "Invalid type [$__type]"
	esac
}
image_build_fat() {
	mkfs.fat $__image
	cdsrc $ver_syslinux
	sudo bios/linux/syslinux -i $__image || die "syslinux"
	# Add kernel, initrd and config
	loop_setup
	pmount 0
	cp $kernel $mnt
	cp $__initrd $mnt/initrd
	cat > $mnt/syslinux.cfg <<EOF
DEFAULT Linux
LABEL Linux
  KERNEL bzImage
  INITRD initrd
EOF
	$disk unmount
	$disk loop-delete
}
image_build_mbr() {
	# For MBR we use "extlinux", so the bootable partition must be a
	# Linux partition with an "ext" file-system.
	echo "label: mbr\n,16MiB,L,*\n,,L," | sfdisk $__image || die sfdisk
	$disk mkext --p=1 -- -t ext3 || die "mkext p1"
	$disk mkext --p=2 -- -t ext3 || die "mkext p2"
	loop_setup
	pmount 1
	sudo cp $kernel $mnt
	sudo cp $__initrd $mnt/initrd
	sudo tee $mnt/syslinux.cfg > /dev/null <<EOF
DEFAULT Linux
LABEL Linux
  KERNEL bzImage
  INITRD initrd
EOF
	cdsrc $ver_syslinux
	sudo bios/extlinux/extlinux -i -s $mnt || log "FAILED: extlinux"
	$disk unmount
	$disk loop-delete
	dd conv=notrunc if=bios/mbr/mbr.bin of=$__image
}
image_build_gpt() {
	echo "label: gpt\n,34MiB,U,\n,,L,*" | sfdisk $__image || die sfdisk
	# sfdisk doesn't set the "legacy BIOS bootable" bit (but it isn't needed)
	sgdisk -A 2:set:2 $__image
	# Format partitions. The EFI partition should be FAT preferably FAT32
	# NOTE: FAT32 needs a >32MiB partition. 34MiB works fine.
	$disk mkfat --p=1 -- -F32 || die "mkfat"
	$disk mkext --p=2 -- -t ext3 || die "mkext"

	loop_setup
	pmount 1
	cp $kernel $mnt
	cp $__initrd $mnt/initrd
	cat > $mnt/startup.nsh <<EOF
FS0:bzImage initrd=initrd
EOF
	$disk unmount
	$disk loop-delete
}
##   edk2_build
##     Build edk2 (the qemu-uefi bios)
cmd_edk2_build() {
	test -d $edk2d/.git || die "Edk2 must be cloned to [$edk2d]"
	cd $edk2d
	git clean -dxf
	make -j$(nproc) -C BaseTools || die BaseTools
	. ./edksetup.sh
	cat > Conf/target.txt <<EOF
ACTIVE_PLATFORM       = MdeModulePkg/MdeModulePkg.dsc
TOOL_CHAIN_TAG        = GCC5
TARGET_ARCH           = X64
TARGET                = DEBUG
TOOL_CHAIN_CONF       = Conf/tools_def.txt
BUILD_RULE_CONF = Conf/build_rule.txt
EOF
	build
	sed -i -e 's,MdeModulePkg/MdeModulePkg.dsc,OvmfPkg/OvmfPkgX64.dsc,' \
		Conf/target.txt
	build
}
##   syslinux_build
##     Shouldn't be necessary really
cmd_syslinux_build() {
	__clean=yes
	cdsrc $ver_syslinux
	patch -p1 -b < $dir/config/$ver_syslinux.patch
	make -j$(nproc)
}
##   uboot_build [--board=] [--default] [--menuconfig]
##     Build U-boot. "initconfig" tries to get the defconfig for the board
cmd_uboot_build() {
	cdsrc $ver_uboot
	export CROSS_COMPILE=$__arch-linux-gnu-
	test "$__clean" = "yes" && rm -rf $__ubootobj
	mkdir -p $__ubootobj
	local make="make O=$__ubootobj -j$(nproc)"
	if test "$__default" = "yes"; then
		$make ${__board}_defconfig || die "make ${__board}_defconfig"
		cp $__ubootobj/.config $__uboot_cfg || "create $__uboot_cfg"
		__menuconfig=yes
	fi
	test -r "$__uboot_cfg" || die "Not readable [$__uboot_cfg]"
	cp $__uboot_cfg $__ubootobj/.config
	if test "$__menuconfig" = "yes"; then
		$make menuconfig || die "make menuconfig"
		cp $__ubootobj/.config $__uboot_cfg
	fi
	$make
}
##   uboot-image [--bootscr=script]
##     Create an image and install files used by u-boot.
##     The (hush) script will be used to create a 'boot.scr' image
##     that will be executed by u-boot on startup
cmd_uboot_image() {
	$me image_build --type=gpt  # This will install the kernel and initrd
	loop_setup
	pmount 1
	rm -f $mnt/startup.nsh		# (used by OVMF, not u-boot)
	local mkimage=$__ubootobj/tools/mkimage
	$mkimage -T script -d $__bootscr $mnt/boot.scr
	cp $__ubootobj/arch/arm/dts/qemu-arm64.dtb $mnt/virt.dtb
	$disk unmount --p=1
	$disk loop-delete
}
#   uboot
#     Install or run (sandbox) U-boot
cmd_uboot() {
	cdsrc $ver_uboot
	cd obj-$__board || die "Not built?"
	if test "$__board" = "sandbox"; then
		test "$__arch" = "x86_64" || die "arch [$__arch]"
		xterm -e ./u-boot -d u-boot.dtb -l
		return
	fi
}
##   grub_build
##     Build GRUB.
cmd_grub_build() {
	cdsrc $ver_grub
	#https://www.linuxfromscratch.org/lfs/view/development/chapter08/grub.html
	echo depends bli part_gpt > grub-core/extra_deps.lst
	./configure --host=$__arch-linux-gnu || die "configure"
	make -j$(nproc) || die make
	make DESTDIR=$PWD/sys install || die "make install"
}
##   qemu [--uefi]
##     Start a qemu VM. --ktest start with -kernel/-initrd (no disk)
cmd_qemu() {
	eval $($qemu env | grep __tap)
	rm -rf $tmp					# (since we 'exec')
	$qemu run --hd --image=$__image --bios=$__ubootobj/u-boot.bin
	# (qemu.sh will ignore --bios for arch=x86_64)
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
