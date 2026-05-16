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

# passage des variables dans le chroot
cat > /mnt/tmp/vars.sh << EOF
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
PASSWORD="$PASSWORD"
USER_MAIN="$USER_MAIN"
USER_SON="$USER_SON"
GROUP_SHARED="$GROUP_SHARED"
DISK="$DISK"
MOUNT_VBOX="$MOUNT_VBOX"
MOUNT_SHARED="$MOUNT_SHARED"
EOF

arch-chroot /mnt /bin/bash << 'CHROOT'

source /tmp/vars.sh

# timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# locale
sed -i "s/#$LOCALE UTF-8/$LOCALE UTF-8/" /etc/locale.gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
locale-gen

# hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# hooks mkinitcpio pour LUKS et LVM
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# GRUB avec support LUKS
LUKS_UUID=$(blkid -s UUID -o value "${DISK}2")
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:cryptlvm root=/dev/vg_arch/lv_root\"|" /etc/default/grub
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# services au démarrage
systemctl enable NetworkManager
systemctl enable sshd

# mot de passe root
echo "root:$PASSWORD" | chpasswd

# groupe partagé père/fils
groupadd $GROUP_SHARED

# collegue : admin avec sudo et virtualbox
useradd -m -G wheel,audio,video,storage,vboxusers,$GROUP_SHARED -s /bin/bash $USER_MAIN
echo "$USER_MAIN:$PASSWORD" | chpasswd

# fils : usage C uniquement, pas de sudo
useradd -m -G audio,video,$GROUP_SHARED -s /bin/bash $USER_SON
echo "$USER_SON:$PASSWORD" | chpasswd

# activation sudo pour wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# dossier partagé avec setgid pour héritage du groupe
chown root:$GROUP_SHARED $MOUNT_SHARED
chmod 2775 $MOUNT_SHARED

# dossier vbox appartient à collegue
chown $USER_MAIN:vboxusers $MOUNT_VBOX
chmod 775 $MOUNT_VBOX

# mise à jour et paquets graphiques
pacman -Syu --noconfirm

pacman -S --noconfirm xorg-server xorg-xinit xorg-xrandr xorg-xsetroot

# i3 et outils associés
pacman -S --noconfirm i3-wm i3status i3lock dmenu rofi picom feh alacritty

# display manager
pacman -S --noconfirm lightdm lightdm-gtk-greeter
systemctl enable lightdm

# polices
pacman -S --noconfirm ttf-dejavu ttf-font-awesome noto-fonts

# navigateur
pacman -S --noconfirm firefox

# outils C pour le fils, pas d'IDE
pacman -S --noconfirm gcc gdb make valgrind

# éditeurs
pacman -S --noconfirm vim nano

# virtualbox
pacman -S --noconfirm virtualbox virtualbox-host-modules-arch

# outils système
pacman -S --noconfirm htop tmux unzip zip tree ncdu thunar gparted nmap net-tools

# config i3 pour collegue
mkdir -p /home/$USER_MAIN/.config/i3

cat > /home/$USER_MAIN/.config/i3/config << 'I3CONF'
set $mod Mod4

font pango:DejaVu Sans Mono 10

gaps inner 8
gaps outer 4
default_border pixel 2

exec --no-startup-id picom
exec --no-startup-id nm-applet
exec --no-startup-id xsetroot -solid "#1e1e2e"
