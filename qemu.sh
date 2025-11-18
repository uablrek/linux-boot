#! /bin/sh
##
## qemu.sh --
##
##   Help script for running kvm/qemu.
##
##   Even though this script is named "qemu.sh", actually all
##   functions except "run", like build-kernel, build-initrd, etc. are
##   generic.
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
me=$dir/$prg
tmp=/tmp/tmp/$USER/${prg}_$$

die() {
	echo "ERROR: $*" >&2
	cd $dir						# (if we are on $tmp)
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
	f=$HOME/Downloads/$1
	test -r $f && return 0
	test -n "$ARCHIVE" && f=$ARCHIVE/$1
	test -r $f
}
findar() {
	findf $1.tar.bz2 || findf $1.tar.gz || findf $1.tar.xz || findf $1.zip
}
# Set variables unless already defined. Vars are collected into $opts
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
	cd $WS/$1
}
##   env
##     Print environment.
cmd_env() {
	test "$envset" = "yes" && return 0
	envset=yes
	eset \
		ver_kernel=linux-6.17.1 \
		ver_busybox=busybox-1.36.1
	test "$cmd" = "versions" && return
	unset opts

	test -n "$long_opts" && export $long_opts
	eset ARCHIVE=$HOME/archive
	eset FSEARCH_PATH=$HOME/Downloads:$ARCHIVE
	eset KERNELDIR=$HOME/tmp/linux
	eset WS=/tmp/tmp/$USER/qemu
	eset __arch='x86_64'
	eset \
		__musl='no' \
		musldir=$HOME/tmp/musl-cross-make \
		__kcfg=$dir/config/$__arch/$ver_kernel \
		__kdir=$KERNELDIR/$ver_kernel \
		__kobj=$WS/obj/$ver_kernel \
		__bbcfg=$dir/config/$ver_busybox \
		__initrd=$WS/initrd.bz2 \
		__mem=1G \
		__smp=2 \
		disk=$dir/disk.sh \
		__image=$WS/hd.img \
		__adr=192.168.55.1/24 \
		__tap=qtap

	if test "$__arch" = "aarch64"; then
		eset kernel=$__kobj/arch/arm64/boot/Image.gz
	else
		eset kernel=$__kobj/arch/x86/boot/bzImage
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
	fi

	if test "$cmd" = "env"; then
		set | grep -E "^($opts)="
		exit 0
	fi

	if test "$__musl" = "yes"; then
		test -x $musldir/$__arch/bin/$__arch-linux-musl-gcc || \
			die "No musl cross-compiler built for [$__arch]"
		export PATH=$musldir/$__arch/bin:$PATH
		xcompile_cc="CC=$__arch-linux-musl-cc AR=$__arch-linux-musl-ar"
		xcompile_at="--host=$__arch-linux-musl"
		xcompile_meson="--cross-file $dir/config/meson-cross.$__arch"
	elif test "$__arch" = "aarch64"; then
		which aarch64-linux-gnu-gcc > /dev/null || \
			die "No cross-compiler installed for [$__arch]"
		xcompile_cc="CC=$__arch-linux-gnu-gcc AR=$__arch-linux-gnu-ar"
		xcompile_at="--host=$__arch-linux-gnu"
		xcompile_meson="--cross-file $dir/config/meson-cross-gnu.$__arch"		
	fi
	mkdir -p $WS
	cd $dir
}
##   versions [--brief]
##     Print used sw versions
cmd_versions() {
	unset opts
	set | grep -E "^ver_.*="
	test "$__brief" = "yes" && return 0
	local k v
	for k in $(set | grep -E "^ver_.*=" | cut -d= -f1); do
		v=$(eval echo \$$k)
		if findar $v; then
			printf "%-20s (%s)\n" $v $f
		else
			printf "%-20s (archive missing!)\n" $v
		fi
	done
}
##   rebuild [--arch=] [--musl] [ovls...]
##     Rebuild kernel and busybox. Default is native build
cmd_rebuild() {
	local now begin=$(date +%s)
	$me kernel-build --clean || die kernel-build
	$me busybox-build --clean || die busybox-build
	$me initrd-build $@ || die initrd-build
	now=$(date +%s)
	log "Qemu built OK in $((now-begin)) sec"
}
cmd_kernel_unpack() {
	test -d $__kdir && return 0	  # (already unpacked)
	log "Unpack kernel to [$__kdir]..."
	findar $ver_kernel || die "Kernel source not found [$ver_kernel]"
	local d=$(dirname $__kdir)
	mkdir -p $d
	xz -dc -T0 $f | tar -C $d -x
}
##   kernel-build --initconfig=     # Init the kcfg
##   kernel-build [--clean] [--menuconfig]
##     Build the kernel
cmd_kernel_build() {
	cmd_kernel_unpack
	test "$__clean" = "yes" && rm -rf $__kobj
	mkdir -p $__kobj

	local CROSS_COMPILE make targets
	make="make -C $__kdir O=$__kobj"
	if test "$__native" != "yes"; then
		if test "$__arch" = "aarch64"; then
			make="$make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
			targets="Image.gz modules dtbs"
		else
			make="$make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu-"
		fi
	fi
	if test -n "$__initconfig"; then
		rm -r $__kobj
		mkdir -p $__kobj $(dirname $__kcfg)
		$make -C $__kdir O=$__kobj $__initconfig
		cp $__kobj/.config $__kcfg
		test "$__menuconfig" = "yes" || return 0
	fi

	test -r $__kcfg || die "Not readable [$__kcfg]"
	cp $__kcfg $__kobj/.config
	if test "$__menuconfig" = "yes"; then
		$make menuconfig
		cp $__kobj/.config $__kcfg
	else
		$make oldconfig
	fi
	$make -j$(nproc) $targets
}
##   kernel-config [--kcfg=] [--reset] [--kconfiglib] [config-files...]
##     Use the "scripts/config" script, or "kconfiglib", to alter the
##     kernel-config. With --reset the kernel config is initiated from
##     "tinyconfig"
cmd_kernel_config() {
	test "$__reset" = "yes" && \
		$me kernel_build --initconfig=tinyconfig --menuconfig=no
	test -r $__kcfg || die "Not readable [$__kcfg]"
	if test "$__kconfiglib" = "yes"; then
		kernel_config_kconfiglib $@
		return
	fi
	local config="$__kdir/scripts/config --file $__kcfg"
	local cfile k v line
	for cfile in $@; do
		test -r "$cfile" || die "Not readable [$cfile]"
		while read line; do
			echo $line | grep -qE '^[A-Z0-9]' || continue
			log $line
			k=$(echo $line | cut -d= -f1)
			v=$(echo $line | cut -d= -f2-)
			if echo $v | grep -qE '^(y|n|m)$'; then
				case $v in
					y) $config --enable $k;;
					n) $config --disable $k;;
					m) $config --module $k;;
				esac
			elif echo $v | grep -qF '"'; then
				$config --set-str $k "$(echo $v | tr -d '"')"
			else
				$config --set-val $k $v
			fi
		done < $cfile
	done
}
kernel_config_kconfiglib() {
	test -n "$kconfiglib" || die 'Not set [$kconfiglib]'
	test -r $kconfiglib/kconfiglib.py || \
		die "Not readable [$kconfiglib/kconfiglib.py]"
	export PYTHONPATH=$kconfiglib
	local opts cfile
	for cfile in $@; do
		opts=$(grep -E '^[A-Z0-9]' $cfile | tr -d '"')
		SRCARCH=x86 ARCH=x86 CC=gcc LD=ld srctree=$__kdir \
			KERNELVERSION=$ver_kernel KCONFIG_CONFIG=$__kcfg \
			$kconfiglib/setconfig.py $opts || die "kconfiglib"
	done
}
##   busybox_build [--bbcfg=] [--menuconfig]
##     Build BusyBox
cmd_busybox_build() {
	cdsrc $ver_busybox
	if test "$__menuconfig" = "yes"; then
		test -r $__bbcfg && cp $__bbcfg ./.config
		make menuconfig
		cp ./.config $__bbcfg
	else
		test -r $__bbcfg || die "No config"
		cp $__bbcfg ./.config
	fi
	if test "$__musl" = "yes" -o "$__arch" != "x86_64"; then
		local cfg="CONFIG_CROSS_COMPILER_PREFIX"
		local lib=gnu
		test "$__musl" = "yes" && lib=musl
		local prefix=$__arch-linux-$lib-
		sed -i -E "s,$cfg=\"\",$cfg=\"$prefix\"," .config
	fi
	make -j$(nproc) || die make
	return 0
}
##   busybox-install <dest-dir>
##     Install BusyBox. Intended to be called from an ovl/tar
cmd_busybox_install() {
	test -n "$1" || die "No dest-dir"
	local bb=$WS/$ver_busybox/busybox
	test -x $bb || die "Not executable [$bb]"
	mkdir -p "$1" || die "Mkdir [$1]"
	cp $bb "$1" || die "Cp $bb -> $1"
}
##   initrd-build [--initrd=] [ovls...]
##     Build a ramdisk (cpio archive) containing busybox and
##     (optionally) overlays
cmd_initrd_build() {
	local bb=$WS/$ver_busybox/busybox
	test -x $bb || die "Not executable [$bb]"
	rm -f $__initrd

	cmd_gen_init_cpio
	gen_init_cpio=$WS/bin/gen_init_cpio
	mkdir -p $tmp
	cat > $tmp/cpio-list <<EOF
dir /dev 755 0 0
nod /dev/console 644 0 0 c 5 1
dir /bin 755 0 0
dir /etc 755 0 0
file /bin/busybox $bb 755 0 0
slink /bin/sh busybox 755 0 0
EOF
	mkdir -p $tmp/root
	__dest=$tmp/root
	test -n "$1" -o -n "$INITRD_OVL" && \
		cmd_unpack_ovls $INITRD_OVL $@
	test -x $tmp/root/init || \
		cp $dir/config/init-tiny $tmp/root/init
	cmd_emit_list $tmp/root >> $tmp/cpio-list

	local uncompressed=$(echo $__initrd | sed -E 's,\.[a-z0-9]+$,,')
	$gen_init_cpio $tmp/cpio-list > $uncompressed
	local compression=$(echo $__initrd | grep -oE '\.[a-z0-9]+$')
	case $compression in
		.xz)
			xz -T0 $uncompressed || die xz;;
		.gz)
			gzip $uncompressed || die gzip;;
		.bz2)
			bzip2 $uncompressed || die bzip2;;
	esac
}
#   gen_init_cpio
#     Build the kernel gen_init_cpio utility
cmd_gen_init_cpio() {
	local x=$WS/bin/gen_init_cpio
	test -x $x && return 0
	mkdir -p $(dirname $x)
	local src=$__kdir/usr/gen_init_cpio.c
	test -r $src || die "Not readable [$src]"
	gcc -o $x $src
}
#   unpack_ovls --dest= [ovls...]
#     Unpack ovls
cmd_unpack_ovls() {
	test -n "$__dest" || die "No dest"
	test -e $__dest -a ! -d "$__dest" && die "Not a directory [$__dest]"
	mkdir -p $__dest || die "Failed mkdir [$__dest]"
	local ovl
	for ovl in $@; do
		test -x $ovl/tar || die "Not executable [$ovl/tar]"
		$ovl/tar - | tar -C $__dest -x || die "Unpack [$ovl]"
	done
}
##   lsovls <ovls...>
##     List contents of ovl's
cmd_lsovls() {
	test -n "$1" || return 0
	__dest=$tmp
	cmd_unpack_ovls $@
	cd $tmp
	find . ! -type d | sed -E 's,^\./,,'
	cd $dir
}
cmd_lsovl() {
	cmd_lsovls $@
}
#   emit_list <src>
#     Emit a gen_init_cpio list built from the passed <src> dir
cmd_emit_list() {
	test -n "$1" || die "No source"
	local x p target d=$1
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
	for x in $(find . -mindepth 1 -type l | cut -c2-); do
		target=$(readlink $d$x)
		echo "slink $x $target 777 0 0"
	done
}
##   modules-install --dest=
##     Install kernel modules
cmd_modules_install() {
	test -n "$__dest" || die "No --dest"
	mkdir -p $__dest || die "Mkdir [$__dest]"
	test -r "$__kobj/Makefile" || die "Not readable [$__kobj/Makefile]"
    INSTALL_MOD_PATH=$__dest make -j$(nproc) -C $__kobj modules_install \
        1>&2 > /dev/null || die "Failed to install modules from [$__kobj]"
}
##   lsmod
##     List modules built (not loaded) in the kernel
cmd_lsmod() {
	__dest=$tmp
	cmd_modules_install
	find $tmp -name '*.ko' | grep -oE '[^/]+.ko$' | sed -e 's,\.ko,,'
}
##   mkimage --clean      # just delete the image
##   mkimage [--image=] [--size=400MiB] [--tar] <ovls...>
##     Create a hard-disk image. The disk can be created in 2 ways:
##     1. A VFAT formatted partition with "rootfs.tar" file
##     2. An ext4 formatted partition with the rootfs
##     Option 2 requires "sudo".
cmd_mkimage() {
	rm -f $__image
	test "$__clean" = "yes" && return 0
	test -x $disk || die "Not executable [$disk]"
	eset __size=400MiB
	export __image __size
	if test "$__tar" = "yes"; then
		mkimage_fat $@
	else
		mkimage_ext4 $@
	fi
}
mkimage_fat() {
	$disk mkimage --fat || die "$disk mkimage"
	$disk mkfat --p=1 || die "mkfat p1"
	$disk mkfat --p=2 -- -n qemu-data || die "mkfat p2"
	test -n "$1" || return 0	# (an empty disk)
	__dest=$tmp/fs
	cmd_unpack_ovls $@ || die "unpack-ovls"
	cd $tmp/fs
	tar -cf $tmp/rootfs.tar * || die "tar rootfs.tar"
	cd $dir
	__dev=$($disk loop-setup)
	echo $__dev | grep '/dev/loop' || die loop-setup
	export __dev
	local mnt=$($disk mount --p=2)
	log "Mount at [$mnt]"
	test -n "$mnt" -a -d "$mnt" || die mount
	local ok
	cp $tmp/rootfs.tar $mnt || ok=no
	$disk unmount --p=2
	$disk loop-delete
	ls -lh $tmp/rootfs.tar
	test "$ok" = "no" && die "Image too small [$__size]"
	return 0
}
mkimage_ext4() {
	$disk mkimage || die "$disk mkimage"
	$disk mkfat --p=1 || die "mkfat p1"
	$disk mkext --p=2 -- -t ext4 -L qemu-data || die "mkext p2"
	test -n "$1" || return 0	# (an empty disk)
	__dest=$tmp
	cmd_unpack_ovls $@ || die "unpack-ovls"
	__dev=$($disk loop-setup)
	echo $__dev | grep '/dev/loop' || die loop-setup
	export __dev
	local mnt=$($disk mount --p=2)
	log "Mount at [$mnt]"
	test -n "$mnt" -a -d "$mnt" || die mount
	sudo cp -R $tmp/* $mnt
	sudo chown -R 0:0 $mnt/*
	$disk unmount --p=2
	$disk loop-delete
}
##   mktap [--bridge=] [--adr=] [--tap=]
##     Create a tap device and a (optional) bridge. Requires "sudo"!
cmd_mktap() {
	if ip link show dev $__tap > /dev/null 2>&1; then
		log "Device exists [$__tap]"
		return 0
	fi
	sudo ip tuntap add $__tap mode tap user $USER || die "Create [$__tap]"
	sudo ip link set up $__tap

	# If we don't have a bridge, set the address on the tap device
	if test -z "$__bridge"; then
		sudo ip addr add $__adr dev $__tap || die "Add address to tap"
		return 0
	fi
	# Create the bridge if needed, and attach the tap
	if ip link show dev $__bridge > /dev/null 2>&1; then
		# This may be "docker0"
		sudo ip link set dev $__tap master $__bridge || die "Attach to bridge"
	else
		sudo ip link add name $__bridge type bridge group_fwd_mask 0x4000 \
			|| die "Failed to create [$__bridge]"
		sudo ip link set up $__bridge
		sudo ip addr add $__adr dev $__bridge || die "Add address to bridge"
		sudo ip link set dev $__tap master $__bridge || die "Attach to bridge"
	fi
}
##   dhcpd --dev=<interface> --dns= [--conf=]
##     Start a DHCP server on the specified interface.
cmd_dhcpd() {
	if test -r /var/run/udhcpd.pid; then
		local pid=$(cat /var/run/udhcpd.pid)
		log "busybox udhcpd already running as pid $pid"
		return 0
	fi
	test -n "$__dev" || die "No interface specified"
	test -n "$__dns" || die "No DNS address specified"
	eset __busybox=$WS/$ver_busybox/busybox
	test -x $__busybox || die "Not executable [$__busybox]"
	eset leases=$WS/udhcpd.leases
	truncate -s0 $leases

	if test -z "$__conf"; then
		get_address $__dev			# (sets: adr and subnet)
		__conf=$WS/udhcpd.conf
		local rng=$(echo $adr | cut -d. -f1-3)
		sed -e "s,eth0,$__dev," -e "s,/tmp/udhcpd.leases,$leases," \
			-e "s,10.0.0.1,$adr," -e "s,10.0.0.100,$rng.100," \
			-e "s,10.0.0.200,$rng.200," -e "s,10.0.10.1,$__dns," \
			-e "s,255.255.255.0,$subnet," \
			< $dir/config/udhcpd.conf > $__conf
	fi
	sudo $__busybox udhcpd -S $__conf || die "udhcpd"
	sleep 0.2
	test -r /var/run/udhcpd.pid || die "dhcpd not started"
}
cmd_dhcpd_stop() {
	test -r /var/run/udhcpd.pid || die "busybox udhcpd is not running"
	local pid=$(cat /var/run/udhcpd.pid)
	log "Killing server pid [$pid] ..."
	sudo kill $pid
	sleep 0.2
	test -r /var/run/udhcpd.pid && die "udhcpd refuses to die"
	local leases=$WS/udhcpd.leases
	sudo rm -f $leases
}
# Get the ipv4 addresses of a device. Sets "adr" and "subnet"
# Only prefix=16|24 are handled
get_address() {
	local o=$(ip -j addr show $1)
	test -n "$o" || die "Couldn't find device [$1]"
	local ifinfo=$(echo $o | jq -r '.[].addr_info[]|select(.family == "inet")')
	adr=$(echo $ifinfo | jq -r .local)
	local prefix=$(echo $ifinfo | jq -r .prefixlen)
	case $prefix in
		24) subnet=255.255.255.0;;
		16) subnet=255.255.0.0;;
		*) die "Unsupported prefix [$prefix]";;
	esac
}
##   run --arch=aarch64 [--graphic] [--hd --bios=]
##   run --arch=x86_64 [--graphic] [--iso=] [--hd] [--uefi]
##     Start a qemu VM. If --iso is specified, install a Linux distro, and
##     use "--hd --graphic" for subsequent boots.
cmd_run() {
	qemu_$__arch $@
}
qemu_x86_64() {
	local opt
	# The "-boot order=..." command does not seem to
	# work with UEFI, so "bootindex=" must be used. If "bootindex="
	# is NOT used, it seems like pxe-boot is hard-coded in qemu
	local i=0
	if test -n "$__iso"; then
		# Mount an ISO image and boot from it (no kernel or initrd)
		test -r "$__iso" || die "Not readable [$__iso]"
		opt="$opt -drive file=$__iso,index=$i,media=cdrom,format=raw,readonly=on,force-share=on,if=none,id=cdrom"
		opt="$opt -device virtio-blk-pci,drive=cdrom,bootindex=$i"
		i=$((i + 1))
		__hd=yes
		__graphic=yes
		opt="$opt -boot once=d"
	fi
	if test -r "$__image"; then
		opt="$opt -drive file=$__image,index=$i,media=disk,if=none,format=raw,id=hd"
		opt="$opt -device virtio-blk-pci,drive=hd,bootindex=$i"
		i=$((i + 1))
	fi
	if ip link show $__tap > /dev/null 2>&1; then
		opt="$opt -netdev tap,id=qtap,script=no,ifname=$__tap"
		opt="$opt -device virtio-net-pci,netdev=qtap"
	fi
	if test "$__graphic" = "yes"; then
		# "-vga std"
		# "-vga virtio"
		# "-device virtio-gpu-pci"
		#opt="-device virtio-gpu-gl-pci"
		#opt="-device qxl -display gtk,gl=on"
		#opt="-device virtio-gpu-pci -display gtk,gl=on"
		opt="$opt -device virtio-gpu-pci -display sdl"
	else
		opt="$opt -nographic"
	fi
	if test "$__uefi" = "yes"; then
		log "Starting with UEFI..."
		cp $OVMF_VARS $WS/OVMF_VARS
		opt="$opt -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
		opt="$opt -drive if=pflash,format=raw,file=$WS/OVMF_VARS"
	fi
	if test "$__hd" = "yes"; then
		test -r "$__image" || die "Not readable [$__image]"
	else
		test -r $kernel || die "Not readable [$kernel]"
		test -r $__initrd || die "Not readable [$__initrd]"
		opt="$opt -kernel $kernel -initrd $__initrd"
		opt="$opt -append init=/init $__append"
	fi
	rm -rf $tmp					# (since we 'exec')
	exec qemu-system-x86_64 -enable-kvm -M q35 -m $__mem -smp $__smp \
		-monitor none -serial stdio $opt $@
}
qemu_aarch64() {
	test -n "$__iso" && die "ISO-boot is only supported for x86_64"
	test -n "$__uefi" && die "UEFI is only supported for x86_64"
	local opt=-nographic
	if test "$__graphic" = "yes"; then
		opt="-device virtio-gpu-pci -display sdl"
	fi
	if test -r "$__image"; then
		#https://forums.gentoo.org/viewtopic-t-1167745-start-0.html
		opt="$opt -drive if=none,file=$__image,format=raw,id=hd"
		opt="$opt -device virtio-blk-device,drive=hd"
	fi
	if ip link show $__tap > /dev/null 2>&1; then
		opt="$opt -netdev tap,id=qtap,script=no,ifname=$__tap"
		opt="$opt -device virtio-net-pci,netdev=qtap"
	fi
	if test "$__hd" = "yes"; then
		test -r "$__image" || die "Not readable [$__image]"
		test -n "$__bios" || die "--hd requires a bios (U-boot)"
		test -r "$__bios" || die "Not readable [$__bios]"
		opt="$opt -bios $__bios"
	else
		test -r $kernel || die "Not readable [$kernel]"
		test -r $__initrd || die "Not readable [$__initrd]"
		opt="$opt -kernel $kernel  -initrd $__initrd"
		opt="$opt -append init=/init $__append"
	fi
	
	local now=$(date +%s)
	rm -rf $tmp					# (since we 'exec')
	exec qemu-system-aarch64 -cpu cortex-a72 -m $__mem -smp 2 \
		-machine virt,virtualization=on,secure=off \
		-monitor none -serial stdio $opt $@
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
cd $dir						# (if we are on $tmp)
rm -rf $tmp
exit $status
