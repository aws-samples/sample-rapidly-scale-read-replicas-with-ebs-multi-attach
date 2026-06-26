#!/usr/bin/env bash
# Phase 2: Compile RocksDB and configure services. Run after Phase 1 + reboot.
set -euo pipefail

# Ensure full PATH — systemd-run uses a restricted environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

ROCKSDB_VERSION="v9.7.4"
INSTALL_PREFIX="/usr/local"
BUILD_DIR="/tmp/rocksdb-build"

echo "==> Phase 2: Building RocksDB..."

echo "==> Cloning RocksDB ${ROCKSDB_VERSION}..."
rm -rf "${BUILD_DIR}"
git clone --depth 1 --branch "${ROCKSDB_VERSION}" \
    https://github.com/facebook/rocksdb.git "${BUILD_DIR}"

cd "${BUILD_DIR}"
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DWITH_SNAPPY=ON -DWITH_ZLIB=ON -DWITH_BZ2=ON \
    -DWITH_LZ4=ON -DWITH_ZSTD=ON -DWITH_GFLAGS=ON \
    -DROCKSDB_BUILD_SHARED=ON -DWITH_TOOLS=ON \
    -DWITH_TESTS=OFF -DWITH_BENCHMARK_TOOLS=OFF

make -j"$(nproc)" rocksdb ldb

echo "==> Installing RocksDB..."
sudo make install
sudo cp tools/ldb "${INSTALL_PREFIX}/bin/"
echo "${INSTALL_PREFIX}/lib" | sudo tee /etc/ld.so.conf.d/rocksdb.conf
sudo ldconfig

BUILD_FILES="/home/ubuntu/build"

echo "==> Building REST service..."
g++ -std=c++17 -O2 -o /tmp/rocksdb_service \
    "${BUILD_FILES}/rocksdb_service.cc" \
    -I"${INSTALL_PREFIX}/include" \
    -L"${INSTALL_PREFIX}/lib" \
    -lrocksdb -lsnappy -lz -lbz2 -llz4 -lzstd -lgflags -lpthread -ldl
sudo cp /tmp/rocksdb_service "${INSTALL_PREFIX}/bin/rocksdb_service"

echo "==> Configuring systemd services..."

sudo tee /etc/systemd/system/rocksdb.service > /dev/null <<'UNIT'
[Unit]
Description=RocksDB REST Service
After=network.target local-fs.target pacemaker.service
[Service]
Type=simple
EnvironmentFile=/etc/rocksdb/service.env
# Wait for GFS2 mount before opening DB — prevents corrupting DB on reboot before mount
ExecStartPre=/bin/bash -c 'until mountpoint -q /data/rocksdb && [ -d /data/rocksdb/db ]; do sleep 2; done'
ExecStart=/usr/local/bin/rocksdb_service ${DB_PATH} ${MODE} ${PORT}
# If starting as writer, ensure cluster-watcher is running (handles promote case)
ExecStartPost=/bin/bash -c 'grep -q MODE=readwrite /etc/rocksdb/service.env && systemctl enable cluster-watcher.service && systemctl start cluster-watcher.service || true'
Restart=always
RestartSec=5
TimeoutStopSec=300
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

sudo mkdir -p /etc/rocksdb
sudo tee /etc/rocksdb/service.env > /dev/null <<'ENV'
DB_PATH=/data/rocksdb/db
MODE=readwrite
PORT=8080
ENV

sudo tee /etc/systemd/system/cluster-watcher.service > /dev/null <<'WATCHUNIT'
[Unit]
Description=RocksDB Cluster Node Watcher
After=pacemaker.service
[Service]
Type=simple
EnvironmentFile=/etc/rocksdb/cluster.env
ExecStart=/usr/local/bin/cluster_watcher.sh ${CLUSTER_NAME} ${REGION}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
WATCHUNIT

sudo tee /etc/rocksdb/cluster.env > /dev/null <<'CLENV'
CLUSTER_NAME=rocksdb-cluster
REGION=us-east-1
CLENV

sudo cp "${BUILD_FILES}/cluster_self_remove.sh" /usr/local/bin/cluster_self_remove.sh
sudo chmod +x /usr/local/bin/cluster_self_remove.sh

sudo tee /etc/systemd/system/cluster-self-remove.service > /dev/null <<'HOOKUNIT'
[Unit]
Description=Remove this node from GFS2 cluster on shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=network.target corosync.service pacemaker.service
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=/usr/local/bin/cluster_self_remove.sh
TimeoutStopSec=60
[Install]
WantedBy=multi-user.target
HOOKUNIT

sudo cp "${BUILD_FILES}/cluster_key_sync.sh" /usr/local/bin/cluster_key_sync.sh
sudo chmod +x /usr/local/bin/cluster_key_sync.sh

sudo tee /etc/systemd/system/cluster-key-sync.service > /dev/null <<'KSSVC'
[Unit]
Description=Sync cluster auth keys from SSM
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cluster_key_sync.sh
KSSVC

sudo tee /etc/systemd/system/cluster-key-sync.timer > /dev/null <<'KSTIMER'
[Unit]
Description=Poll SSM for cluster auth key changes
[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
[Install]
WantedBy=timers.target
KSTIMER

sudo systemctl daemon-reload
sudo systemctl enable rocksdb.service
sudo systemctl enable cluster-self-remove.service
sudo systemctl enable cluster-key-sync.timer

echo "==> Loading kernel modules..."
sudo modprobe dlm
sudo modprobe gfs2
echo "dlm" | sudo tee /etc/modules-load.d/dlm.conf
echo "gfs2" | sudo tee /etc/modules-load.d/gfs2.conf

# Disable corosync/pacemaker auto-start — they must only be started by
# pcs cluster start (writer userdata or cluster watcher).
sudo systemctl disable corosync pacemaker 2>/dev/null || true

# Enable corosync auto-restart on failure — when corosync exits during ring
# membership changes at startup, systemd will restart it automatically.
sudo mkdir -p /etc/systemd/system/corosync.service.d
sudo tee /etc/systemd/system/corosync.service.d/restart.conf > /dev/null <<'CORO_OVERRIDE'
[Service]
Restart=always
RestartSec=5
CORO_OVERRIDE
sudo systemctl daemon-reload

# Wrap fence_aws to handle already-terminated instances.
# Stock fence_aws fails for terminated instances, causing DLM to hang permanently.
sudo cp /usr/sbin/fence_aws /usr/sbin/fence_aws.real 2>/dev/null || true
sudo cp "${BUILD_FILES}/fence_aws_wrapper.sh" /usr/sbin/fence_aws
sudo chmod +x /usr/sbin/fence_aws

# Disable cloud-init package updates on deployed instances — prevents first-boot
# apt upgrades from setting reboot-required and triggering an unexpected reboot
sudo sed -i 's/^package_update:.*/package_update: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
sudo sed -i 's/^package_upgrade:.*/package_upgrade: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
sudo sed -i 's/^package_reboot_if_required:.*/package_reboot_if_required: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
# Write override file — processed last, wins over defaults
sudo tee /etc/cloud/cloud.cfg.d/99-no-updates.cfg > /dev/null <<'CLOUDCFG'
package_update: false
package_upgrade: false
package_reboot_if_required: false
CLOUDCFG

# ── Disable automatic apt updates + unattended-upgrades auto-reboot ───────────
# Unattended kernel upgrades trigger an automatic OS reboot, which knocks nodes
# out of corosync/Pacemaker mid-operation (membership churn, possible fencing).
# Mask the systemd units so they cannot run even if unattended-upgrades is later
# pulled back in as a dependency, and pin the apt config as defense-in-depth.
sudo systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
sudo apt-get purge -y -q unattended-upgrades 2>/dev/null || true
sudo systemctl mask unattended-upgrades.service \
    apt-daily.timer apt-daily.service \
    apt-daily-upgrade.timer apt-daily-upgrade.service 2>/dev/null || true
sudo tee /etc/apt/apt.conf.d/99-disable-auto-upgrades > /dev/null <<'APTCFG'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
APTCFG

# Copy cluster watcher
if [ -f "${BUILD_FILES}/cluster_watcher.sh" ]; then
    sudo cp "${BUILD_FILES}/cluster_watcher.sh" /usr/local/bin/cluster_watcher.sh
    sudo chmod +x /usr/local/bin/cluster_watcher.sh
fi

# Clean up build files
rm -rf "${BUILD_FILES}" /tmp/rocksdb-build 2>/dev/null || true

echo "==> Verifying..."
/usr/local/bin/ldb --version

echo "==> Phase 2 complete. RocksDB installed successfully."
