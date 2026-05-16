#!/bin/bash

set -e

# variables
DISK="/dev/sda"
PASSWORD="azerty123"
HOSTNAME="archlinux"
TIMEZONE="Europe/Paris"
LOCALE="fr_FR.UTF-8"
KEYMAP="fr"

USER_MAIN="collegue"
USER_SON="fils"
GROUP_SHARED="famille"

MOUNT_VBOX="/opt/vbox"
MOUNT_SHARED="/srv/shared"

# vérification UEFI
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "Erreur : pas en mode UEFI"
    exit 1
fi

# vérification internet
ping -c 1 archlinux.org > /dev/null 2>&1 || { echo "Pas de connexion internet"; exit 1; }

timedatectl set-ntp true

# partitionnement : sda1 EFI 512M, sda2 pour LUKS+LVM
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 "$DISK"
sgdisk -n 2:0:0     -t 2:8e00 "$DISK"
partprobe "$DISK"
sleep 2
# chiffrement LUKS sur sda2
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 "${DISK}2" -
echo -n "$PASSWORD" | cryptsetup open "${DISK}2" cryptlvm -

# LVM
pvcreate /dev/mapper/cryptlvm
vgcreate vg_arch /dev/mapper/cryptlvm

lvcreate -L 8G       -n lv_swap   vg_arch
lvcreate -L 20G      -n lv_root   vg_arch
lvcreate -L 20G      -n lv_vbox   vg_arch
lvcreate -L 5G       -n lv_shared vg_arch
lvcreate -L 10G      -n lv_luks   vg_arch
lvcreate -l 100%FREE -n lv_home   vg_arch

# formatage
mkfs.fat -F32 "${DISK}1"
mkswap /dev/vg_arch/lv_swap
mkfs.ext4 /dev/vg_arch/lv_root
mkfs.ext4 /dev/vg_arch/lv_home
mkfs.ext4 /dev/vg_arch/lv_vbox
mkfs.ext4 /dev/vg_arch/lv_shared

# lv_luks : volume chiffré sans montage automatique, monté à la main par l'utilisateur
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 /dev/vg_arch/lv_luks -
echo -n "$PASSWORD" | cryptsetup open /dev/vg_arch/lv_luks lv_luks_open -
mkfs.ext4 /dev/mapper/lv_luks_open
cryptsetup close lv_luks_open

# montage
mount /dev/vg_arch/lv_root /mnt
mkdir -p /mnt/boot/efi /mnt/home /mnt${MOUNT_VBOX} /mnt${MOUNT_SHARED}

mount "${DISK}1"             /mnt/boot/efi
mount /dev/vg_arch/lv_home   /mnt/home
mount /dev/vg_arch/lv_vbox   /mnt${MOUNT_VBOX}
mount /dev/vg_arch/lv_shared /mnt${MOUNT_SHARED}
swapon /dev/vg_arch/lv_swap

# installation du système de base
pacstrap -K /mnt \
    base base-devel \
    linux linux-firmware linux-headers \
    lvm2 cryptsetup \
    grub efibootmgr \
    networkmanager \
    sudo vim nano git \
    man-db man-pages \
    curl wget \
    bash-completion \
    openssh \
    zsh

genfstab -U /mnt >> /mnt/etc/fstab
