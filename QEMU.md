# The qemu.sh script

The `qemu.sh` was originally intended as a [kvm/qemu](
https://www.qemu.org/) help script, but most functions are generic,
like building kernels and images. `qemu.sh` can be used as a
stand-alone utility, but is intended to be paired by an `admin.sh`
script that builds and installs the application.

Both `x86_64` and `aarch64` architectures are supported.

## Build kernel and BusyBox

```
. ./Envsettings   # define convenient aliases. Assumed from now on!
qemu rebuild
```

## Initrd only

The VM never leaves the `initrd`. No hard-disk image is needed.
```
qemu initrd-build
qemu run
```

To install the application do:
```
qemu initrd-build ovl/admin-install
# or to install abother application
ADMIN=/path/to/another/admin.sh qemu initrd-build ovl/admin-install
qemu run
```
This assumes that the `admin.sh` script has an "install" function.


## Initrd and hard-disk

The `initrd` is limited in size (ram/2), so for larger systems it can't
be used. Instead, use a hard-disk.

```
qemu initrd-build ovl/modules ovl/hard-disk
qemu mkimage ovl/rootfs ovl/admin-install   # (requires sudo)
qemu run
```

The qemu `-kernel/-initrd` is still used, so UEFI boot is *not* used,
even though the hd-image has a EFI partition by default.

## Ramdisk and hard-disk

This is a "hybrid" setup I intend to use on SoC boards (RPi4 and
Rock4se). I don't want to have the rootfs on the SD-card, but use a
ramdisk. With 4G ram and small applications, it shouldn't be a
problem. The hard-disk now contains a `rootfs.tar` file which is
unpacked to a ramdisk (tempfs) on startup.

```
qemu initrd-build ovl/ramdisk
qemu mkimage --tar ovl/rootfs ovl/admin-install
qemu run
```

## UEFI

By default QEMU starts with a BIOS. This must be replaced with
[Open Virtual Machine Firmware UEFI](http://www.tianocore.org/ovmf/)
(OVMF) firmware.

```
#sudo apt install ovmf
cp /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd .
qemu ... \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS_4M.fd
```
**NOTE**: In many places the `--bios` option is proposed. I haven't got
that to work. "pflash" works fine though.

To boot with uefi:
```
qemu run --uefi ...
```

A program to manipulate uefi VARS is [virt-fw-vars](
https://gitlab.com/kraxel/virt-firmware/-/tree/master):

```
#apt install python3-virt-firmware
virt-fw-vars -i /usr/share/OVMF/OVMF_VARS_4M.fd -p
# (empty)
```

NOTE: To avoid pxe-boot as default (why?) you **must** specify
`bootindex=0` for the hard-drive image!


## Linux distributions

A Linux distribution can be booted from an ISO-image. Example:
```
# Be sure to allocate enough disk and memory. You may have to experiment.
# (Alpine Linux is happy with the defaults, Ubuntu is definitely NOT!)
export __image=/tmp/alpine.img
truncate -s 8G $__image
export __smp=8        # (default is 2)
export __mem=8G       # (default is 1G)
qemu run --iso=$HOME/Downloads/alpine-standard-3.22.2-x86_64.iso -cpu host
```
NOTE: The distro must be able to install on virtual block devices (/dev/vda)

Linux distributions requires a network to be useful. That can be
tricky, but you may piggy-back on `docker` if you have it
installed. The `docker0` interface is setup as a bridge with
masquerading to the external network. But you also need a DHCP server:

```
qemu busybox-build
# (sudo required for these:)
qemu mktap --bridge=docker0
qemu dhcpd --dev=docker0 --dns=(address)
```
Examine `/etc/resolv.conf` to get the --dnsaddress. But if it is
localhost (127.0.0.1) you must [fix it](
https://askubuntu.com/questions/907246/how-to-disable-systemd-resolved-in-ubuntu).

