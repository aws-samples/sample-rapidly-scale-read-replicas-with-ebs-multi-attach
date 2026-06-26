#!/usr/bin/env bash
# Phase 1: Install all packages. Suppresses any auto-reboot during install,
# then explicitly reboots at the end so the new kernel modules are loaded cleanly.
# After reboot, run setup_phase2.sh to compile RocksDB and configure services.
set -euo pipefail

echo "==> Phase 1: Installing packages..."
echo "==> Waiting for cloud-init to finish..."
cloud-init status --wait 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

# Wait for apt locks
for _i in $(seq 1 60); do
    if ! sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null; then
        break
    fi
    echo "  Waiting for apt lock... (${_i}/60)"
    sleep 5
done

# Remove unattended-upgrades to prevent background apt operations
sudo systemctl stop unattended-upgrades.service 2>/dev/null || true
sudo systemctl disable unattended-upgrades.service 2>/dev/null || true
sudo apt-get remove -y -q unattended-upgrades 2>/dev/null || true

# Disable needrestart completely — it triggers interactive prompts and schedules reboots
# via systemd-logind when kernel modules are updated
sudo mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "l";' | sudo tee /etc/needrestart/conf.d/no-restart.conf > /dev/null
echo '$nrconf{kernelhints} = 0;' | sudo tee -a /etc/needrestart/conf.d/no-restart.conf > /dev/null
sudo rm -f /etc/apt/apt.conf.d/99needrestart 2>/dev/null || true
sudo rm -f /usr/lib/needrestart/apt-pinvoke 2>/dev/null || true

# Mask reboot.target so nothing can trigger a reboot during package install
sudo systemctl mask reboot.target

# Wait for apt locks again after unattended-upgrades removal
for _i in $(seq 1 60); do
    if ! sudo fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null; then
        break
    fi
    echo "  Waiting for apt lock... (${_i}/60)"
    sleep 5
done

echo "==> Installing build dependencies + GFS2 stack..."
sudo apt-get update -q
sudo NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive apt-get install -y -q --fix-missing \
    git cmake g++ make \
    libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev \
    libgflags-dev libssl-dev \
    pcs pacemaker corosync fence-agents-aws \
    gfs2-utils lvm2 dlm-controld \
    pacemaker-cli-utils resource-agents-extra \
    linux-modules-extra-"$(uname -r)" \
    linux-modules-extra-aws

# Cancel any pending reboot that snuck through
sudo shutdown -c 2>/dev/null || true
sudo rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

# Pin the kernel FIRST before upgrading — prevents upgrade from installing a newer kernel
sudo apt-mark hold linux-aws linux-image-aws linux-headers-aws linux-modules-extra-aws 2>/dev/null || true
for PKG in $(dpkg -l 'linux-*-aws' 2>/dev/null | awk '/^ii/{print $2}'); do
    sudo apt-mark hold "$PKG" 2>/dev/null || true
    echo "  Held: $PKG"
done

# Upgrade all non-kernel packages now so deployed instances have nothing to upgrade.
# This means cloud-init's package_upgrade on first boot finds nothing to do → no reboot.
sudo NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q 2>/dev/null || true
sudo rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

echo "==> Installing AWS CLI..."
sudo snap install aws-cli --classic

# Unmask reboot.target before we reboot
sudo systemctl unmask reboot.target

echo "==> Phase 1 complete. Rebooting to load new kernel modules..."
sudo reboot
