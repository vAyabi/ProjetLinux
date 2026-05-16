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
