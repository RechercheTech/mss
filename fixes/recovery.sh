#!/bin/bash
# recovery.sh 
#
# Copyright (c) 2014 CyberOrg Info
# Copyright (c) 2016 Recherche Tech LLP
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
#
# Authors:      Jigish Gohil <cyberorg@cyberorg.info>
#               Shrenik Bhura <shrenik.bhura@gmail.com>
#
# This script creates rescue archive for system recovery
# and provides ways to restore it.

fsck -f -y / >/dev/null 2>&1 || true
mount -o remount rw / 2>/dev/null || true
logfile=${msssetuplogfile:-"/var/log/recovery.log"}
log() {
	local now="RECOVERY: $(date "+%R:%S"):"
	echo "$now $*"
	echo "$now $*" >>$logfile
}

need_help() {
    cat <<EOF

Run as:
$0 <command> [option]

Available commands and options are:
add_to_grub                : Add recovery option to grub menu
backup_config              : Backup all configuration data stored at /etc
backup_home                : Create backup of user home directories on external storage media 
backup_mbr                 : Create backup of MBR
create [snapshot_name]     : Create recovery archives. Snapshot with an auto-generated numeric id is created if no snapshot name is given
create_dri /dev/<usb>      : Create a Disaster Recovery Image on an external USB media. Used to restore to a new hard disk in case of a hard disk failure
create_usb /dev/<usb>      : Create rescue USB media. This is useful to restore when boot from the hard disk fails
list_snapshots             : Lists all snapshots available to restore from
restore <snapshot_name>    : Use from running system. Values for snapshot_name - 'factory' restores factory state, 'last' restores last backup, 
                             no snapshot_name lists all snapshots
restore_dri /dev/<usb>	   : Restore from a Disaster Recovery Image saved on external USB media
restore_factory_external   : Restore to factory state. Use from recovery boot entry or rescue USB media. Doesn't modify data in users' home directories
restore_ltsp               : Restore LTSP image
restore_mbr                : Restore MBR from the last backup
restore_offlineweb         : Restore offline web content residing at /var/www/html

Example: 
$0 create new-backup : creates a snapshot named 'new-backup'

For more details, visit https://docs.myscoolserver.com
EOF
}

are_you_sure ()  {
        echo  -n "$1 [$2/$3]? "
        while true; do
                read answer
                case $answer in
                        y | Y | yes | YES ) answer="y"; break;;
                        n | N | no | NO ) exit;;
                        *) echo "Please answer (y)es or (n)o.";;
                esac
        done
}

list_usb_storage () {
	local count=0
	for device in /sys/block/*;	do
		if udevadm info --query=property --path=$device | grep -q ^ID_BUS=usb; then
		echo "/dev/`echo $device | cut -d/ -f4`"
		((++count))
		fi
	done
	[ "$count" -eq "0" ] && echo "No USB storage devices found."
}

valid_usb_storage () {
	device="/sys/block/`echo $1 | cut -d/ -f3`"
    if udevadm info --query=property --path=$device | grep -q ^ID_BUS=usb; then
    	echo true
	else
		echo false
	fi
}

request_usb_storage_path () {
	echo "$1 Connected USB devices: "
	list_usb_storage
	read -p "Enter USB storage device path. (Ctrl+c) to exit now: " usbpath
	echo $usbpath
}

get_connected_usb_storage_dev () {
	if [ x"$1" = x ]; then
		usbdev=$(request_usb_storage_path "Requires second parameter as USB storage device path.")
	else
		usbdev=$1
	fi
	if [ "$usbdev" = /dev/sda ]; then
		usbdev=$(request_usb_storage_path "Device entered is the main disk. Use USB storage device instead.")
 	fi
	if [ `valid_usb_storage $usbdev` == "true" ]; then
		echo $usbdev
	else	
		log "$usbdev not found, exiting"
		exit 0
	fi
}

list_snapshots () {
	LANG=en_US.UTF-8 borg list /recovery/system
}

fsck_mount_get_vars () {
	for i in $(fdisk -l | grep '/dev/sd' | grep -v swap | grep -v Disk | awk '{print $1}'); do
		log "Running fsck on $i"
		fsck -f -y $i
		mkdir -p /tmp/$i
		log "mounting $i at /tmp/$i"
		mount $i /tmp/$i
		if [ -f /tmp/$i/.restorevars ]; then
			log "Restore variables found at /tmp/$i/.restorevars"
			. /tmp/$i/.restorevars
		fi
        if [ -f /tmp/$i/.restorevarsusb ]; then
            log "Using USB device found at $i"
			export recoverypart=/$i
        fi
		echo "$i" >> /tmp/mounts
		umount /tmp/"$i"
	done
	rootpart=${rootpart:-/dev/sda3}
	homepart=${homepart:-/dev/sda5}
	recoverypart=${recoverypart:-/dev/sda4}
	backup_before_restore_files=${backup_before_restore_files:-etc}
	sysdisk=$(echo $rootpart | sed 's@[1-9]@@')
	rootpartmount=/tmp/"$rootpart"
	homepartmount=/tmp/"$homepart"
	recoverypartmount=/tmp/"$recoverypart"
	mkdir -p $rootpartmount $homepartmount $recoverypartmount
	log "mounting root $rootpart to $rootpartmount"
	mount "$rootpart" "$rootpartmount"
	log "mounting home $homepart to $homepartmount"
	mount "$homepart" "$homepartmount"
	log "mounting recovery partition $recoverypart to $recoverypartmount"
	mount "$recoverypart" "$recoverypartmount"
	backupfiles=${backupfiles:-/etc/passwd /etc/shadow /etc/group}
}

create_restorevars () {
	rootpart="/dev/disk/by-uuid/$(blkid -s UUID -o value $(mount | grep " / " |awk '{print $1}'))"
	homepart="/dev/disk/by-uuid/$(blkid -s UUID -o value $(mount | grep " /home " |awk '{print $1}'))"
	recoverypart="/dev/disk/by-uuid/$(blkid -s UUID -o value $(mount | grep " /recovery " |awk '{print $1}'))"
	if grep -q rootpart /recovery/.restorevars 2>/dev/null; then
		sed -i -e "s@rootpart=.*@rootpart=$rootpart@" /recovery/.restorevars
		sed -i -e "s@homepart=.*@homepart=$homepart@" /recovery/.restorevars
		sed -i -e "s@recoverypart=.*@recoverypart=$recoverypart@" /recovery/.restorevars
	else
		echo "rootpart=$rootpart" > /recovery/.restorevars
		echo "homepart=$homepart" >> /recovery/.restorevars
                echo "recoverypart=$recoverypart" >> /recovery/.restorevars
		echo "backup_before_restore=true" >> /recovery/.restorevars
	fi
}

add_to_grub () {
	log "Adding grub menu entry"
	rootdev=$(cat /boot/grub/grub.cfg|grep "set root" | head -1 | cut -d \' -f2)
	rootpartuuid=$(blkid -s UUID -o value $(mount | grep " / " |awk '{print $1}'))
cat > /etc/grub.d/40_custom <<- EOF
#!/bin/sh
exec tail -n +3 \$0
submenu 'Factory Restore' {
menuentry 'Factory Restore - Are you sure? Ctl+Alt+Del to cancel' --class os {
        load_video
        set gfxpayload=keep
        insmod gzio
        insmod part_msdos
        insmod ext2
        echo    'Loading Linux ...'
        linux   /usr/share/recovery/vmlinuz-recovery root=UUID=$rootpartuuid showopts quiet splash
        echo    'Loading recovery ramdisk ...'
        initrd  /usr/share/recovery/initrd-recovery
}
menuentry 'Recovery shell' --class os {
        insmod gzio
        insmod part_msdos
        insmod ext2
        set gfxpayload=keep
        echo    'Loading Linux ...'
        linux   /usr/share/recovery/vmlinuz-recovery root=UUID=$rootpartuuid recoveryshell showopts quiet splash kiwidebug=1
        echo    'Loading recovery ...'
        initrd  /usr/share/recovery/initrd-recovery
}
}
EOF
	log "Creating grub.cfg"
	grub-mkconfig -o /boot/grub/grub.cfg
}

create () {
	add_to_grub
	cat > /recovery/recexclude <<- EOF
/dev 
/proc
/sys
/home
/tmp
/var/tmp
/var/run
/var/cache
/srv/ltsp/mssraspi/*
/srv/ltsp/mssraspiro/*
/srv/ltsp/mssraspiwork/*
/srv/ltsp/images/*
/srv/ubuntu-livecd/*
/var/spool
/var/lib/named
/run
/var/log
/var/www/html/mss
/mnt
/recovery
/media
/installer
EOF
	snapshot=$1
	if [ x$snapshot = x ]; then
		snapshot=$(date -d "today" +"%Y%m%d%H%M")
	fi
	log "Creating recovery archive, do not reboot/interrupt till it is done.."
	if [ ! -d /recovery/system ]; then
		LANG=en_US.UTF-8 borg init --encryption=none /recovery/system
	fi
	LANG=en_US.UTF-8 borg create --stats --progress --compression lz4 --exclude-from /recovery/recexclude /recovery/system::$snapshot /
	log "Recovery archives can be found here: /recovery/"
	log "Execute 'recovery.sh list_snapshots' to list all archives" 
	if awk 'BEGIN{exit_code=1} $2 == "/" {exit_code=0} END{exit exit_code}' /proc/mounts; then
	       create_restorevars
	else
		log "Cannot create restorevars in chroot"
	fi
}

backup_home () {
	log "Visit URL - https://bit.ly/mssbackup for detailed instructions"
}

backup_config () {
	log "Backing up /etc"
	cd / && tar --numeric-owner --hard-dereference -Jcpf /recovery/.recoveryetc.tar.xz ./etc
}

backup_mbr () {
	log "Taking backup of MBR"
	dd if=/dev/sda of=/recovery/.mbrbackup bs=512 count=1
	log "Backup MBR can be found here: /recovery/.mbrbackup"
}

restore_factory_external () {
	fsck_mount_get_vars
	if [ ! -b $rootpart ]; then
		log "root partition not found, exiting"
		exit 0
	fi
	if [ -d /$recoverypartmount/system ]; then
		borgmount=$(mktemp -d)
		if ! `LANG=en_US.UTF-8 borg mount /$recoverypartmount/system::factory $borgmount`; then
			log "Archive factory does not exist. Nothing to do."
			cat /var/log/recovery.log >> $rootpartmount/var/log/recovery.log 2>/dev/null || true
			exit 1
		fi
		if [ x"backup_before_restore" == xtrue ]; then
			cd /$rootpartmount/
			tar cf /$recoverypartmount/.backup_before_restore.tar $backup_before_restore_files
		fi
		log "Backing up $backupfiles"
		for i in $backupfiles; do
			if [ -f /$rootpartmount/$i ]; then
				log "copying $i to /$rootpartmount/$i-recovery-backup"
				cp /$rootpartmount/$i /$rootpartmount/$i-recovery-backup
			fi
		done
        log "Restoring to default Factory settings, do not reboot till it is done..."
		cd /$rootpartmount/
		for i in dev proc sys; do
			if [ ! -d $i ]; then
				mkdir -p $i
			fi
		done
		rsync -avP $borgmount/* /$rootpartmount/
		umount $borgmount && rmdir $borgmount
		if [ ! -d /$rootpartmount/srv/ltsp/images ]; then
			mkdir -p /$rootpartmount/srv/ltsp/images
		fi
		if [ -f /$recoverypartmount/.ltsp ]; then
			cp /$recoverypartmount/.ltsp /$rootpartmount/srv/ltsp/images/amd64.img
		fi
		if [ -f /$recoverypartmount/.ltspmssraspi ]; then
			cp /$recoverypartmount/.ltspmssraspi /$rootpartmount/srv/ltsp/images/mssraspi.img
		fi
		log "Restoring finished, rebooting..."
	else
		log "Recovery file not found"
	fi
	cat /var/log/recovery.log >> $rootpartmount/var/log/recovery.log 2>/dev/null || true
	cd / 
	log "Unmounting all partitions mounted for recovery"
	for i in $(cat /tmp/mounts); do
		umount -l /tmp/"$i" 2>/dev/null && rmdir /tmp/"$i" || true
	done
	umount $rootpartmount $homepartmount $recoverypartmount 2>/dev/null
	rmdir $rootpartmount $homepartmount $recoverypartmount 2>/dev/null	
	rmdir /tmp/dev/disk/* || true
	rmdir /tmp/dev/* || true
	rmdir /tmp/dev || true
	rm /tmp/mounts
}

restore_offlineweb () {
	log "Restoring offline web content..."
	for i in /recovery/offlinewebarchives/*; do log "Restoring $i"; pv -e -p -t -a -b $i | tar xf -C /; done
	cd /var/www/html/mss/indexer/ && ./indexer.sh && cd -
	log "Restoring offline web content finished"
}

restore_ltsp () {
	if [ -f /recovery/.ltsp -a -f /recovery/.ltspmssraspi ]; then
		log "Restoring LTSP images"
		if [ ! -d /srv/ltsp/images ]; then
			mkdir -p /srv/ltsp/images
		fi
		pv -e -p --timer --average-rate --bytes /recovery/.ltsp > /srv/ltsp/images/amd64.img
		pv -e -p --timer --average-rate --bytes /recovery/.ltspmssraspi > /srv/ltsp/images/mssraspi.img

		ltsp kernel /srv/ltsp/images/amd64.img
		/usr/bin/mssltsp raspiremount
		ltsp ipxe

		log "Restoring LTSP images finished"
	fi
}

restore () {
    if [ -d /recovery/system ]; then
		cd /
                for i in dev proc sys; do
                        if [ ! -d $i ]; then
                                mkdir -p $i
                        fi
                done
		if [ x"$1" = x ]; then
			echo -e "\nMust specify snapshot name to restore. Snapshots available -\nName\t\t\t\t\tTimestamp"
			list_snapshots
			read -p "Name of snapshot to restore (Ctrl+c to exit now): " snaprec 
		else
			snaprec=$1
		fi
		if [ x"$1" = xlast ]; then
			snaprec=$(LANG=en_US.UTF-8 borg list --last 1 /recovery/system | cut -d" " -f1 2>/dev/null)
		fi
		log "Restoring to snapshot $snaprec, do not reboot/interrupt till it is done..."
        borgmount=$(mktemp -d)
        LANG=en_US.UTF-8 borg mount /recovery/system::$snaprec $borgmount
        rsync -avP $borgmount/* /
        umount $borgmount && rmdir $borgmount
		restore_ltsp
		restore_offlineweb
		log "Restoring finished, reboot is recommended"
    else
         log "Recovery file not found"
    fi
}

restore_mbr () {
        if [ -f /recovery/.mbrbackup ]; then
		log "Restoring MBR"
		dd if=/recovery/.mbrbackup of=$sysdisk bs=512 count=1
		log "MBR restore done"
	else
		log "MBR backup not found"
	fi
}

recovery_stick_menu () {
cat > $stickmount/boot/grub/grub.cfg <<- EOF
submenu 'Factory Restore' {
menuentry 'Factory Restore - Are you sure? Ctl+Alt+Del to cancel' --class os {
        insmod gzio
        insmod part_msdos
        insmod ext2
        insmod efi_gop
        insmod efi_uga
        insmod video_bochs
        insmod video_cirrus
        set gfxpayload=keep
        echo    'Loading Linux ...'
        linux   /boot/vmlinuz-recovery showopts quiet splash 
        echo    'Loading recovery...'
        initrd  /boot/initrd-recovery
}
menuentry 'Recovery shell' --class os {
        insmod gzio
        insmod part_msdos
        insmod ext2
		insmod efi_gop
		insmod efi_uga
		insmod video_bochs
		insmod video_cirrus
        set gfxpayload=keep
        echo    'Loading Linux ...'
        linux   /boot/vmlinuz-recovery recoveryshell showopts quiet splash kiwidebug=1
        echo    'Loading recovery ...'
        initrd  /boot/initrd-recovery
}
}
EOF
}

create_usb () {
	$stick=$(get_connected_usb_storage_dev $1)
	sizerequired=$(du -ch /recovery/system /recovery/.ltsp /recovery/.ltspmssraspi | tail -1)
	log "Minimum $sizerequired USB storage device required"
	log "The target device $stick will be completely wiped"
   	are_you_sure "continue ?" "y" "n"
	log "Preparing Recovery device on $stick" 
	log "wiping and creating paritions"
	dd if=/dev/zero of=$stick bs=4M count=3
	fdisk $stick <<EOF
g
n


+200M
t
1
n



w

EOF
	sync
	sleep 3
	partprobe
	sleep 3
	stickmount=$(mktemp -d)
	stickpart="$stick"2
	efipart="$stick"1
	log "Creating filesystem on $efipart"
    mkfs.vfat -n EFI $efipart
	log "Creating filesystem on $stickpart" 
	mkfs.ext4 -L Rescue $stickpart
	sync
    sleep 2
	mount $stickpart $stickmount
	touch $stickmount/.restorevarsusb
	mkdir -p $stickmount/boot/efi
	mount $efipart $stickmount/boot/efi
	log "Installing grub on $stick"
	grub-install --force --efi-directory=/$stickmount/boot/efi --boot-directory=/$stickmount/boot $stick --removable --recheck
	log "Creating boot menu"
	recovery_stick_menu
	if [ ! -d /recovery/system ]; then
		create usb_snapshot
	fi
	log "Copying files on Recovery device"
	cp /usr/share/recovery/* /$stickmount/boot/
	rsync -aP /recovery/system /$stickmount/
	rsync -aP /srv/ltsp/images/amd64.img /$stickmount/.ltsp
	rsync -aP /srv/ltsp/images/mssraspi.img /$stickmount/.ltspmssraspi
	cp /recovery/.restorevars /$stickmount/
	log "Clean up"
	sync
    umount /$stickmount/boot/efi
	umount /$stickmount
	rmdir /$stickmount
	log "Recovery device ready"
}

create_dri () {
	if [ ! -f /tmp/recoveryshell ]; then
		log "Disaster Recovery Image can only be created from the recovery shell. Reboot and choose Factory Restore > Recovery Shell from Grub menu."
		exit 0
	fi
	storage=$(get_connected_usb_storage_dev $1)
	storagepart="$storage"1 # Assuming that the USB storage has only one partition. May change this to list all partitions and ask which one to use.
	backupmedia="/mnt/backupmedia"
	mkdir /mnt/boot /mnt/root /mnt/home /mnt/recovery $backupmedia
	mount /dev/sda1 /mnt/boot
	mount /dev/sda3 /mnt/root
	mount /dev/sda4 /mnt/recovery
	mount /dev/sda5 /mnt/home
	mount $storagepart $backupmedia
	sizerequired=$(df --output=used --total -x tmpfs -x devtmpfs | tail -1)
	sizeavailable=$(df --output=avail $storagepart | tail -1)
	if [ $sizeavailable -lt $sizerequired ]; then
		sizerequiredh=$(df -h --output=used --total -x tmpfs -x devtmpfs | tail -1)
		sizeavailableh=$(df -h --output=avail $storagepart | tail -1)
		log "Not enough space available on external storage media - $storage. $sizerequiredh required, but only $sizevailableh available."
		umount -a 2> /dev/null
		exit 0 
	fi
	umount /mnt/boot/ /mnt/root /mnt/recovery /mnt/home
   	are_you_sure "The recovery image creation may take up to 4 hours. Proceed with recovery image creation to $storagepart now?" "y" "n"
	mkdir /mnt/tmp
	log "Preparation phase started..."
    for i in 1 {3..5}; do
		mount /dev/sda$1 /mnt/tmp
		dd if=/dev/zero of=/mnt/tmp/zero_file bs=32M 2>/dev/null
		sync
		rm /mnt/tmp/zero_file
		umount /dev/sda$1
	done
	log "Preparation completed"
	log "Writing image file to external media"
	backupdir=$backupmedia/mss-dri
	mkdir $backupdir
	pv -EE -B 32m /dev/sda | dd of=$backupdir/mss-image.img bs=512 conv=sparse
	sync
	(cd $backupdir && md5sum mss-image.img) > $backupdir/mss-image-hash
	echo $(fdisk -l | grep $hdd | grep Disk | cut -d: -f2 | cut -dG -f1 | cut -d. -f1) > $backupdir/origin-hdd
	umount $backupmedia
	log "Disaster Recovery Image 'mss-image.img' successfully created on the external media."
}

cleanup_exit () {
	umount -a 2> /dev/null
	exit 0
}
# Restore from recoveryshell of the MSS or of recovery USB media created. 
restore_dri () {
	if [ ! -f /tmp/recoveryshell ]; then
		log "Disaster Recovery Image can only be restored from the recovery shell. Reboot and choose Factory Restore > Recovery Shell from Grub menu."
		exit 0
	fi

	storage=$(get_connected_usb_storage_dev $1)
	storagepart="$storage"1 # Assuming that the image is stored on USB storage's first partition. May change this to list all partitions and ask which one to use.
	imagemedia="/mnt/restoremedia"
	mkdir $imagemedia
	mount $storagepart $imagemedia
	imagedir=$imagemedia/mss-dri
	# Check if all files required for restoration are present
	if [ ! -f $imagedir/mss-image.img -o ! -f $imagedir/origin-hdd -o ! -f $imagedir/mss-image-hash ]; then
		log "Disaster Recovery Image (mss-image.img) or information (origin-hdd, mss-image-hash) not found on external media $storage. "
		cleanup_exit
	fi
	# Check if destination media exists and is a SATA HDD
	hdd="/dev/sda"
	device="/sys/block/`echo $hdd | cut -d/ -f3`"
	if [ ! udevadm info --query=property --path=$device | grep -q ^ID_BUS=ata ]; then
		log "No hard disk found to restore the Disaster Recovery Image to"
		cleanup_exit
	fi
	# Check if destination disk is large enough
	originsize=$(cat $imagedir/origin-hdd)
    hddsize=$(fdisk -l | grep $hdd | grep Disk | cut -d: -f2 | cut -dG -f1 | cut -d. -f1)
	if [ $hddsize -lt $originsize ]; then
		log "Can't proceed with restoration. Destination disk ($hddsize GB) is smaller than image's origin disk ($originsize GB)."
		cleanup_exit
	fi
	# Check integrity of image
	cd $imagedir
	if ! md5sum --status -c mss-image-hash; then
		log "Disaster Recovery Image is damaged"
		cleanup_exit
	fi

	are_you_sure "Proceed with restoration of Disaster Recovery Image? WARNING: Answering 'YES' shall overwrite all data on the $hdd. \
	The restoration may take up to 4 hours" "YES" "NO"
	pv < /$imagedir/mss-image.img > /dev/sda
	log "Disaster Recovery Image successfully written to the hard disk. Remove rescue media and reboot."
	cleanup_exit
}

if [ x"$1" = x"" ]; then
	need_help
	exit 0
fi
if cat /proc/cmdline | grep -q recoveryshell; then
	if [ ! -f /tmp/recoveryshell ]; then
		touch /tmp/recoveryshell
		bash
	else
		$1
		rm /tmp/recoveryshell
	fi
else
	case "$1" in
	'add_to_grub'|'backup_config'|'backup_home'|'backup_mbr'|'create'| \
	'create_dri'|'create_usb'|'list_snapshots'|'restore'|'restore_dri'| \
	'restore_factory_external'|'restore_ltsp'|'restore_mbr'| \
	'restore_offlineweb' )
		$1 $2
		;;
	*) log "Invalid command - '$1'"
		need_help
		;;
	esac 
fi
exit 0
