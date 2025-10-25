# Linux boot

Boot examples with Linux. A small Linux kernel with initrd is loaded
in a Qemu VM with different disk partitions and bootloaders.

[Development and contributions](#development-and-contributions) are
described below.


Most tasks can be done with the `admin.sh` script:
```
./admin.sh                     # Help printout
./admin.sh env                 # Current env
./admin.sh versions            # Used SW
./admin.sh setup               # Builds everything needed
```

After setup you can test boot with different images:
```
./admin.sh image_build --type=gpt   # default
./admin.sh qemu --uefi
./admin.sh image_build --type=fat   # requires sudo
./admin.sh qemu
./admin.sh image_build --type=mbr   # requires sudo
./admin.sh qemu
```

Tools:

1. **sfdisk** - Handle partitions from script
2. **sgdisk** - Command-line GPT manipulator
3. **udisksctl** - Mount images without root or sudo

## Disks

Disks are created as "raw" images. This is simply a file, created for
example with:

```
#cd to/temp/dir
truncate -s 16MiB hd.img
ls -lsh hd.img
0 -rw-rw-r-- 1 uablrek uablrek 16.0M Aug 13 12:16 hd.img
```

This is a [sparse](https://en.wikipedia.org/wiki/Sparse_file) file. It
has a size of 16MiB, but occupy 0 (zero) bytes on disk. That's why
`truncate` is preferred before `fallocate` (`dd` is the worst choice,
and should be the last resort).

The disks can be partitioned with [MBR](
https://en.wikipedia.org/wiki/Master_boot_record) (Master Boot
Record), or with
[GPT](https://en.wikipedia.org/wiki/GUID_Partition_Table) (GUID
Partition Table).  The
[sfdisk](https://man7.org/linux/man-pages/man8/sfdisk.8.html) tool is
used to manipulate partitions. Example:

```
sfdisk hd.img <<EOF
label: gpt
,4MiB,U,
,,L,
EOF
Device       Start   End Sectors Size Type
hd.img1     2048 10239    8192   4M EFI System
hd.img2    10240 30719   20480  10M Linux filesystem
```

Create a FAT file system and loop-back mount:
```
mkfs.fat --offset 2048 hd.img 8192
udisksctl loop-setup -f hd.img
dev=(from the printout above)
udisksctl mount -b ${dev}p1 
# copy files (as your user) to the directory in the printout
udisksctl unmount -b ${dev}p1
udisksctl loop-delete -b $dev
```

## MBR

Master Boot Record is the older way of booting a PC. It is used for
both hard-disks with partitions and media without partitions,
originally floppys, but now USB-sticks, SD-cards, etc.

### Media without partitions

This is the simplest case:

1. Firmware (BIOS) loads the first 512 bytes of the disk. This is the
   primary bootloader, and is unique for any secondary bootloader. It
   is file-system unaware

2. BIOS exectutes the primary bootloader. It's only job is to load and start
   the secondary bootloader.

3. The secondary bootloader is not limited in size and is likely
   file-system aware. It's primary task is to load and start the Linux
   kernel. It may present a load menu to the user

As an example we take [syslinux](
https://www.kernel.org/pub/linux/utils/boot/syslinux/). Syslinux works
on FAT file-systems.

```
truncate -s 16MiB hd.img
mkfs.fat hd.img
sudo syslinux -i hd.img
dd if=hd.img bs=512 count=1 status=none | od -t x1 -Ax --endian=big
```

The `syslinux -i` installs the primary bootloader in the MBR can
copies the secondary bootloader to the file system. It consists of two
files: `ldlinux.sys` and `ldlinux.c32`.


### Media with partitions

The [MBR](https://en.wikipedia.org/wiki/Master_boot_record) now holds
a partition table at the end (0x1be-0x1fd). The table holds 4
partition entries of 16 byte. Let's check it out!

```
rm -f hd.img
truncate -s 32MiB hd.img
sfdisk --no-reread --no-tell-kernel hd.img <<EOF
label: mbr
,8MiB,c,*
,,L,
EOF
sfdisk -V -l hd.img
sfdisk -g hd.img
hd.img: 4 cylinders, 255 heads, 63 sectors/track
dd if=hd.img bs=512 count=1 status=none | od -t x1 -Ax --endian=big
0001b0 00 00 00 00 00 00 00 00 bc ff 72 1c 00 00 80 20
0001c0 21 00 0c 25 24 01 00 08 00 00 00 40 00 00 00 25
0001d0 25 01 83 14 10 04 00 48 00 00 00 b8 00 00 00 00
0001e0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
0001f0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa
```
The first partition:
```
0001be: 80 20 21 00 0c 25 24 01 00 08 00 00 00 40 00 00
80 - active
202100 - CHS-start = 00/20/21, lba = 32 * 63 + (33 - 1) = 2048
0c - Partition = W95 FAT32 (LBA)
252401 - CHS-end = 01/25/24, lba = (255 + 37) * 63 + (36 - 1) = 18431
00 08 00 00 - LBA-start=0x800 (little endian!!)
00 40 00 00 - sectors = 0x4000
```

* LBA = Logical Block Addressing
* CHS = Cylinder Head Sector

## GPT

The [GUID Partition Table](https://en.wikipedia.org/wiki/GUID_Partition_Table)
(GPT) replaces MBR partitioning. It allows more partitions and larger disks.
Let's check it out!

<img src="https://upload.wikimedia.org/wikipedia/commons/0/07/GUID_Partition_Table_Scheme.svg">

```
rm -f hd.img
truncate -s 128MiB hd.img
sfdisk --no-reread --no-tell-kernel hd.img <<EOF
label: gpt
,8MiB,U,
,8MiB,L,*
EOF
sfdisk -V -l hd.img
Device     Start   End Sectors Size Type
hd.img1     2048 18431   16384   8M EFI System
hd.img2    18432 34815   16384   8M Linux filesystem
dd if=hd.img bs=512 status=none | od -t x1 -Ax --endian=big
000000 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
0001c0 02 00 ee ff ff ff 01 00 00 00 ff ff 03 00 00 00
0001d0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
0001f0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa
000200 45 46 49 20 50 41 52 54 00 00 01 00 5c 00 00 00
000210 cf 2e fa 50 00 00 00 00 01 00 00 00 00 00 00 00
000220 ff ff 03 00 00 00 00 00 00 08 00 00 00 00 00 00
000230 de ff 03 00 00 00 00 00 ef 38 9c 97 d2 03 11 4c
000240 80 12 43 fa 71 52 7d f3 02 00 00 00 00 00 00 00
000250 80 00 00 00 80 00 00 00 f3 71 67 54 00 00 00 00
000260 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
000400 28 73 2a c1 1f f8 d2 11 ba 4b 00 a0 c9 3e c9 3b
000410 c7 31 a0 8e f8 6e 00 43 84 c5 da 09 21 61 21 bf
000420 00 08 00 00 00 00 00 00 ff 47 00 00 00 00 00 00
000430 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
000480 af 3d c6 0f 83 84 72 47 8e 79 3d 69 d8 47 7d e4
000490 4b 50 63 6e 86 f8 85 40 bf a1 87 b5 21 79 cb a1
0004a0 00 48 00 00 00 00 00 00 ff 87 00 00 00 00 00 00
0004b0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
7ffbe00 28 73 2a c1 1f f8 d2 11 ba 4b 00 a0 c9 3e c9 3b
7ffbe10 c7 31 a0 8e f8 6e 00 43 84 c5 da 09 21 61 21 bf
7ffbe20 00 08 00 00 00 00 00 00 ff 47 00 00 00 00 00 00
7ffbe30 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
7ffbe80 af 3d c6 0f 83 84 72 47 8e 79 3d 69 d8 47 7d e4
7ffbe90 4b 50 63 6e 86 f8 85 40 bf a1 87 b5 21 79 cb a1
7ffbea0 00 48 00 00 00 00 00 00 ff 87 00 00 00 00 00 00
7ffbeb0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
7fffe00 45 46 49 20 50 41 52 54 00 00 01 00 5c 00 00 00
7fffe10 91 cc 7f dd 00 00 00 00 ff ff 03 00 00 00 00 00
7fffe20 01 00 00 00 00 00 00 00 00 08 00 00 00 00 00 00
7fffe30 de ff 03 00 00 00 00 00 ef 38 9c 97 d2 03 11 4c
7fffe40 80 12 43 fa 71 52 7d f3 df ff 03 00 00 00 00 00
7fffe50 80 00 00 00 80 00 00 00 f3 71 67 54 00 00 00 00
7fffe60 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
*
8000000

sgdisk -c 2:"Linux Boot" hd.img
sgdisk -A 2:set:2 hd.img
sgdisk -i2 hd.img
Partition GUID code: 0FC63DAF-8483-4772-8E79-3D69D8477DE4 (Linux filesystem)
Partition unique GUID: 6E63504B-F886-4085-BFA1-87B52179CBA1
First sector: 18432 (at 9.0 MiB)
Last sector: 34815 (at 17.0 MiB)
Partition size: 16384 sectors (8.0 MiB)
Attribute flags: 0000000000000004
Partition name: 'Linux Boot'
```

## UEFI

[Unified Extensible Firmware Interface](https://en.wikipedia.org/wiki/UEFI)
(UEFI) replaces BIOS for PC booting. UEFI can be used with both MBR
and GPT formatted disks (i.e there is no GPT requirement!).

### QEMU

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

#### EDK2

OVMF is a part of [EDK2](https://github.com/tianocore/edk2) which has
a build system that is... un-intuitive (to put it nicely). Some good
hints can be found [here](https://wiki.ubuntu.com/UEFI/EDK2). If you
*must* build it, try:

```
export edk2d=/your/path/to/edk2
git clone --depth 1 https://github.com/tianocore/edk2.git $edk2d
cd $edk2d
git submodule update --init --depth 1
cd -
./admin.sh edk2_build
```


### The EFI partition

An EFI partition is created with a `U` type to `sfdisk`. It should be
formatted with a FAT file system. The recommendation is FAT32, but
OVMF has no such requirement, but it has this:

**NOTE**: If FAT32 is used on the EFI partition it *must* be larger than
minimum size for FAT32. 34MiB seems about minimum partition size.

### Kernel

```
Power management and ACPI options >
  [*] ACPI (Advanced Configuration and Power Interface) Support
Processor type and features >
  [*] EFI runtime service support
  [*]   EFI stub support
```

CONFIG_EFI_STUB - This kernel feature allows a bzImage to be loaded
  directly by EFI firmware without the use of a bootloader.


## Syslinux

Syslinux is maintained (sort of) in [kernel.org](
https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/). Syslinux hasn't
been updated since 2014 and can't be built with modern tools (i.e.
[1](https://git.openembedded.org/openembedded-core/tree/meta/recipes-devtools/syslinux/syslinux/0010-Workaround-multiple-definition-of-symbol-errors.patch?h=honister),
[2](https://sourceware.org/bugzilla/show_bug.cgi?id=25585),
[3](https://bugs.launchpad.net/ubuntu/+source/virtualbox/+bug/1578424)), so
a [patch](config/syslinux-6.03.patch) is applied when built.
Pre-built binaries are included in the archive, so building locally may not
be needed.

`Syslinux` actually contains several bootloaders:

* syslinux - For FAT file systems
* extlinux - For ext (Linux) file systems
* pxelinux - For network boot
* isolinux - For bootable CD-rom

In the examples `syslinux` is used for boot from non-partitioned media
and `extlinux` for MBR partitioned media.

NOTE: The doc's say that `syslinux` can be used for partitioned media,
but I can't get that to work.


## U-boot

The [U-boot](https://docs.u-boot.org/en/latest/index.html) bootloader
is the main choice for embedded systems or SoC (System on Chip).
There are some *really* great posts on u-boot in [Mike's homepage](
https://krinkinmu.github.io/). Since SoC's often use ARM,
`--arch=aarch64` should be set.

```
export __arch=aarch64
./admin.sh setup
./admin.sh qemu
# Rebuild:
./admin.sh uboot_build --menuconfig
./admin.sh uboot-image
./admin.sh qemu
```

We use GPT partitioned media with an EFI partition. `U-boot` may
work with other configurations, but this seem to be the "normal" way.

### Boot script

U-boot will load and execute the `boot.scr` if it exist on the EFI
partition. You can try your own with:

```
./admin.sh uboot-image --bootscr=/path/to/your/script
./admin.sh qemu
```


## Grub

(work in progress)

GRUB has grown to become huge and complicated. Since I am more
interrested in booting SoC (System on Chip) I will focus on `U-boot`.
Maybe I get back to GRUB later.

Build locally:
```
./admin.sh grub_build --arch=x86_64
./admin.sh grub_build --arch=aarch64
```


## Development and contributions

Issues and PR's are welcome. Please note that the license is CC0-1.0,
meaning that everything you contribute will become public domain.

I use Ubuntu Linux, `24.04.2 LTS` at the moment. Other Linux distros
should work, but are not tested.

Here are some dependencies:
```
sudo apt install -y efitools ovmf fdisk gcc-aarch64-linux-gnu qemu-system-arm
```
I am sure there are plenty more. PR's are welcome for updates here.

By default everything is stored under `/tmp/tmp/$USER` because I mount
a tmpfs (ramdisk) on `/tmp/tmp` for experiments. You may change that
by setting the `$TEMP` environment variable.

Source archives must be downloaded (by you).
```
./admin.sh versions
linux-6.15.4         (/home/uablrek/archive/linux-6.15.4.tar.xz)
busybox-1.36.1       (/home/uablrek/archive/busybox-1.36.1.tar.bz2)
syslinux-6.03        (/home/uablrek/Downloads/syslinux-6.03.tar.xz)
u-boot-2025.07       (/home/uablrek/Downloads/u-boot-2025.07.tar.gz)
grub-2.12            (/home/uablrek/Downloads/grub-2.12.tar.xz)
```
They are searched for in `$HOME/Downloads:$HOME/archive` by default.

The kernel source will be unpacked in `$KERNELDIR` if necessary, which
defaults to `$HOME/tmp/linux`. The kernel is not built in this
directory, so you may write-protect it if you like.