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
# This script creates rescue archive for system recovery
# and provides ways to restore it.
fsck -f -y / 2>/dev/null || true
mount -o remount rw / 2>/dev/null || true
stick=$2
log() {
	local now="RECOVERY: $(date "+%R:%S"):"
	echo "$now $*"
	echo "$now $*" >>/var/log/recovery.log
}
need_help() {
    cat <<EOF 
Run with any of the following options:
$0 create			: create recovery archives
$0 backup_mbr			: create backup of MBR
$0 restore_factory_external	: use this if running this script from recovery boot entry or external media
$0 restore [snapshot number]	: use this if running from within running system, 1(default) is the factory snapshot, 'last' can be used to restore last backup
$0 restore_mbr			: restores MBR with the last backup
$0 add_to_grub			: Add grub menu for recovery
$0 create_usb /dev/\$usb	: Create rescue USB stick
$0 restore_offlineweb	 	: Restore 30GB offline web content
$0 restore_ltsp			: Restore LTSP image
$0 create_homebackup 		: Please contact Recherche Tech LLP http://myscoolserver for customized backup solution 
$0 create_configbackup 		: Backup /etc
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
if [ "$1" = create_usb ]; then
        if [ x"$2" = x ]; then
                echo "Requires second arguement as USB device path, /dev/sdb for example"
               	exit 1
       	fi
        if [ "$2" = /dev/sda ]; then
               	echo "Device is the main disk, use USB disk, /dev/sdb for example"
       	        exit 1
        fi
fi
fsck_mount_get_vars () {
	for i in $(fdisk -l |grep '/dev/sd' |grep -v swap |grep -v Disk| awk '{print $1}');do
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
		#if [ -f /tmp/$i/.recovery.tar.xz ]; then
		#log "Recovery archive found at /tmp/$i/.recovery.tar.xz"
		#	export homepart=$i
		#fi
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
/srv
/var/spool
/var/lib/named
/run
/var/log
/var/www/html
/opt/ltsp
/mnt
/recovery
/media
EOF
	touch /recovery/snapshot
	snapshot=$(cat /recovery/snapshot 2>/dev/null)
	if [ x$snapshot = x ]; then
		snapshot=1
		echo 1 > /recovery/snapshot
	else
		echo $(($snapshot+1)) > /recovery/snapshot
	fi
	snapshot=$(cat /recovery/snapshot 2>/dev/null)
	log "Creating recovery archive, do not reboot/interrupt till it is done.."
	if [ ! -d /recovery/system ]; then
		LANG=en_US.UTF-8 borg init --encryption=none /recovery/system
	fi
	LANG=en_US.UTF-8 borg create --stats --progress --compression lz4 --exclude-from /recovery/recexclude /recovery/system::$snapshot /
	log "Recovery archives can be found here: /recovery/"
	create_restorevars
}
create_homebackup () {
	log "Please contact Recherche Tech LLP http://myscoolserver for customized backup solution"
}
create_configbackup () {
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
	if [ x"backup_before_restore" == xtrue ];then
		cd /$rootpartmount/
		tar cf /$recoverypartmount/.backup_before_restore.tar $backup_before_restore_files
	fi
	if [ -d /$recoverypartmount/system ]; then
		log "Backing up $backupfiles"
		for i in $backupfiles; do
			if [ -f /$rootpartmount/$i ];then
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
		borgmount=$(mktemp -d)
		LANG=en_US.UTF-8 borg mount /$recoverypartmount/system::1 $borgmount
		rsync -avP $borgmount/* /$rootpartmount/
		umount $borgmount && rmdir $borgmount
	        if [ ! -d /$rootpartmount/opt/ltsp/images ]; then
	                mkdir -p /$rootpartmount/opt/ltsp/images
        	fi
                if [ -f /$recoverypartmount/.ltsp ]; then
		        rsync -aP /$recoverypartmount/.ltsp /$rootpartmount/opt/ltsp/images/amd64.img
		fi
                if [ -f /$recoverypartmount/.ltsp.i386 ]; then
                        rsync -aP /$recoverypartmount/.ltsp.i386 /$rootpartmount/opt/ltsp/images/i386.img
                fi
		log "Restoring finished, rebooting..."
	else
		log "Recovery file not found"
	fi
	cp /var/log/recovery.log $rootpartmount/var/log/ 2>/dev/null || true
	cd / 
	log "Unmounting all partitions mounted for recovery"
	for i in $(cat /tmp/mounts);do
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
	log "Restoring offline web content, takes a very long time..."
if [ -f /recovery/.offlineweb ]; then
	offlinewebmount=$(mktemp -d)
	mount /recovery/.offlineweb $offlinewebmount
	if [ ! -d /var/www/html ]; then
		mkdir -p /var/www/html
	fi
	rsync -aP $offlinewebmount/* /var/www/html/
	for i in /recovery/offlinewebarchives/*; do tar xf $i -C /; done
	umount $offlinewebmount
	rmdir $offlinewebmount
        log "Restoring offline web content finished"
fi
}
restore_ltsp () {
if [ -f /recovery/.ltsp ]; then
        log "Restoring LTSP image"
	if [ ! -d /opt/ltsp/images ]; then
		mkdir -p /opt/ltsp/images
	fi
	rsync -aP /recovery/.ltsp /opt/ltsp/images/amd64.img
        if [ -f /recovery/.ltsp.i386 ]; then
                rsync -aP /recovery/.ltsp.i386 /opt/ltsp/images/i386.img
        fi

        log "Restoring LTSP image finished"
fi
}
restore () {
	log "Restoring to default Factory settings, do not reboot/interrupt till it is done..."
        if [ -d /recovery/system ]; then
		cd /
                for i in dev proc sys; do
                        if [ ! -d $i ]; then
                                mkdir -p $i
                        fi
                done
		if [ x"$1" = x ]; then
			snaprec=1
		else
			snaprec=$1
		fi
		if [ x"$1" = xlast ]; then
			snaprec=$(cat /recovery/snapshot 2>/dev/null)
		fi
                borgmount=$(mktemp -d)
                LANG=en_US.UTF-8 borg mount /recovery/system::$snaprec $borgmount
                rsync -avP $borgmount/* /
                umount $borgmount && rmdir $borgmount
#		borg extract -v /recovery/system::1
#		restore_offlineweb
		restore_ltsp
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
	sizerequired=$(du -ch /recovery/system /recovery/.ltsp | tail -1)
	log "Minimum $sizerequired free space is required on USB stick"
	log "The target device $stick will be completely wiped"
       	are_you_sure "continue ?" "y" "n"
	log "Preparing Recovery stick on $stick" 
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
		create
	fi
	log "Copying files on Recovery stick"
	cp /usr/share/recovery/* /$stickmount/boot/
#	cp -r /recovery/system /recovery/.recoveryltsp.tar /$stickmount/
	rsync -aP /recovery/system /$stickmount/
	rsync -aP /opt/ltsp/images/amd64.img /$stickmount/.ltsp
	if [ -f /opt/ltsp/images/i386.img ]; then
		rsync -aP /opt/ltsp/images/i386.img /$stickmount/.ltsp.i386
	fi
	cp /recovery/.restorevars /$stickmount/
	log "Clean up"
	sync
        umount /$stickmount/boot/efi
	umount /$stickmount
	rmdir /$stickmount
	log "Recovery stick ready"
}
if [ x"$1" = x"" ]; then
	need_help
	exit 0
fi
if cat /proc/cmdline |grep -q recoveryshell; then
	if [ ! -f /tmp/recoveryshell ]; then
		touch /tmp/recoveryshell
		bash
	else
		$1
		rm /tmp/recoveryshell
	fi
else
	$1 $2
fi
exit 0

