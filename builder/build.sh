#!/bin/bash -e
set -x
# This script should be run inside of a Docker container only
if [ ! -f /.dockerinit ]; then
  echo "ERROR: script works in Docker only!"
  exit 1
fi

# Hypriot common settings
HYPRIOT_HOSTNAME="black-pearl"
HYPRIOT_GROUPNAME="docker"
HYPRIOT_USERNAME="pirate"
HYPRIOT_PASSWORD="hypriot"

# Build Debian rootfs for ARCH={armhf,arm64,mips,i386,amd64}
# - Debian armhf = ARMv6/ARMv7
# - Debian arm64 = ARMv8/Aarch64
# - Debian mips  = MIPS
# - Debian i386  = Intel/AMD 32-bit
# - Debian amd64 = Intel/AMD 64-bit
BUILD_ARCH="${BUILD_ARCH:-arm64}"
QEMU_ARCH="${QEMU_ARCH}"
HYPRIOT_TAG="${HYPRIOT_TAG:-dirty}"
ROOTFS_DIR="/debian-${BUILD_ARCH}"

# Cleanup
mkdir -p /workspace
rm -fr "${ROOTFS_DIR}"

# Define ARCH dependent settings
if [ -z "${QEMU_ARCH}" ]; then
  DEBOOTSTRAP_CMD="debootstrap"  
else
  DEBOOTSTRAP_CMD="qemu-debootstrap"

  # Tell Linux how to start binaries that need emulation to use Qemu
  update-binfmts --enable qemu-${QEMU_ARCH}
fi

# Debootstrap a minimal Debian Jessie rootfs
${DEBOOTSTRAP_CMD} \
  --arch="${BUILD_ARCH}" \
  --include="apt-transport-https,avahi-daemon,bash-completion,binutils,ca-certificates,curl,git-core,htop,locales,net-tools,openssh-server,parted,sudo,usbutils" \
  --exclude="debfoster" \
  jessie \
  "${ROOTFS_DIR}" \
  http://ftp.debian.org/debian


### Configure Debian ###

# Use standard Debian apt repositories
cat << EOM | chroot "${ROOTFS_DIR}" \
  tee /etc/apt/sources.list
deb http://httpredir.debian.org/debian jessie main
deb-src http://httpredir.debian.org/debian jessie main

deb http://httpredir.debian.org/debian jessie-updates main
deb-src http://httpredir.debian.org/debian jessie-updates main

deb http://security.debian.org/ jessie/updates main
deb-src http://security.debian.org/ jessie/updates main
EOM

# upgrade to latest Debian package versions
chroot "${ROOTFS_DIR}" <<"EOF"
apt-get update
apt-get upgrade -y
EOF


### Configure network and systemd services ###

# Set ethernet interface eth0 to dhcp
cat << EOM | chroot "${ROOTFS_DIR}" \
  tee /etc/systemd/network/eth0.network
[Match]
Name=eth0

[Network]
DHCP=yes
EOM

# Enable networkd
chroot "${ROOTFS_DIR}" \
  systemctl enable systemd-networkd

# Configure and enable resolved
chroot "${ROOTFS_DIR}" <<"EOF"
ln -sfv /run/systemd/resolve/resolv.conf /etc/resolv.conf
DEST=$(readlink -m /etc/resolv.conf)
mkdir -p $(dirname $DEST)
touch /etc/resolv.conf
systemctl enable systemd-resolved
EOF

# Enable NTP with timesyncd
chroot "${ROOTFS_DIR}" \
  sed -i 's|#Servers=|Servers=|g' /etc/systemd/timesyncd.conf
chroot "${ROOTFS_DIR}" \
  systemctl enable systemd-timesyncd
  
# Set default locales to 'en_US.UTF-8'
echo 'en_US.UTF-8 UTF-8' | chroot "${ROOTFS_DIR}" \
  tee -a /etc/locale.gen
chroot "${ROOTFS_DIR}" \
  locale-gen
echo 'locales locales/default_environment_locale select en_US.UTF-8' | chroot "${ROOTFS_DIR}" \
  debconf-set-selections
chroot "${ROOTFS_DIR}" \
  dpkg-reconfigure -f noninteractive locales


### HypriotOS default settings ###

# set hostname
echo "$HYPRIOT_HOSTNAME" | chroot "${ROOTFS_DIR}" \
  tee /etc/hostname

#FIXME: create dedicated Hypriot .deb package
# install bash prompt as skeleton files (root and default for all new users)
cp /builder/files/etc/skel/{.bash_prompt,.bashrc,.profile} $ROOTFS_DIR/root/
cp /builder/files/etc/skel/{.bash_prompt,.bashrc,.profile} $ROOTFS_DIR/etc/skel/

# install Hypriot group and user
chroot "${ROOTFS_DIR}" \
  addgroup --system --quiet $HYPRIOT_GROUPNAME
chroot "${ROOTFS_DIR}" \
  useradd -m $HYPRIOT_USERNAME --group $HYPRIOT_GROUPNAME --shell /bin/bash
echo "$HYPRIOT_USERNAME:$HYPRIOT_PASSWORD" | chroot "${ROOTFS_DIR}" \
  /usr/sbin/chpasswd
# add user to sudoers group
echo "$HYPRIOT_USERNAME ALL=NOPASSWD: ALL" | chroot "${ROOTFS_DIR}"  \
  tee /etc/sudoers.d/user-$HYPRIOT_USERNAME
chroot "${ROOTFS_DIR}" \
  chmod 0440 /etc/sudoers.d/user-$HYPRIOT_USERNAME

# set HypriotOS version infos
echo "HYPRIOT_OS=\"HypriotOS/${BUILD_ARCH}\"" | chroot "${ROOTFS_DIR}" \
  tee -a /etc/os-release
echo "HYPRIOT_TAG=\"${HYPRIOT_TAG}\"" | chroot "${ROOTFS_DIR}" \
  tee -a /etc/os-release


# Package rootfs tarball
umask 0000
tar -czf "/workspace/rootfs-${BUILD_ARCH}.tar.gz" -C "${ROOTFS_DIR}/" .

# Test if rootfs is OK
/builder/test.sh
