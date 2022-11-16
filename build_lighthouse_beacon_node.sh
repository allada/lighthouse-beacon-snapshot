#!/bin/bash
# Copyright 2022 Nathan (Blaise) Bruer
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.W
set -euxo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

function safe_wait() {
  BACKGROUND_PIDS=( $(jobs -p) )
  for PID in "${BACKGROUND_PIDS[@]}"; do
    wait -f $PID
  done
}

# Utility function that will ensure one function with specific name will on system wide.
# This will only have any effect if all other scripts use the same function.
function mutex_function() {
  local function_name="$1"
  set -euxo pipefail

  # Ensure only one instance of this function is running on entire system.
  (
    flock -x $fd
    $function_name
  ) {fd}>/tmp/$function_name.lock
}

function install_prereq() {
  set -euxo pipefail
  # Basic installs.
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y zfsutils-linux unzip pv jq make clang-12 cmake super protobuf-compiler
  # Use clang as our compiler by default if needed.
  ln -s $(which clang-12) /usr/bin/cc || true

  if ! cargo --version 2>&1 >/dev/null ; then
    # Install cargo.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash /dev/stdin -y
    source "$HOME/.cargo/env"
    rustup install 1.64.0
    rustup default 1.64.0
  fi
}

function setup_drives() {
  set -euxo pipefail
  if zfs list tank ; then
    return # Our drives are probably already setup.
  fi
  # Creates a new pool with the default device.
  DEVICES=( $(lsblk --fs --json | jq -r '.blockdevices[] | select(.children == null and .fstype == null) | .name') )
  DEVICES_FULLNAME=()
  for DEVICE in "${DEVICES[@]}"; do
    DEVICES_FULLNAME+=("/dev/$DEVICE")
  done
  zpool create -o ashift=12 tank "${DEVICES_FULLNAME[@]}"
  # The root tank dataset does not get mounted.
  zfs set mountpoint=none tank

  # Configures ZFS to be slightly more optimal for our use case.
  zfs set compression=lz4 tank
  # Note: The data is about 50% compressible and disk IO is not much of a bottleneck, so use very
  # large record sizes. You can increase performance by reducing this number.
  zfs set recordsize=1M tank
  # Note: Remove most of these if you need your data to be safe across computer
  # unintended shutdowns.
  zfs set sync=disabled tank
  zfs set redundant_metadata=most tank
  zfs set atime=off tank
  zfs set logbias=throughput tank
}

function install_zstd() {
  set -euxo pipefail
  if pzstd --help ; then
    return # pzstd is already installed.
  fi
  # Download, setup and install zstd v1.5.2.
  # We use an upgraded version rather than what ubuntu uses because
  # 1.5.0+ greatly improved performance (3-5x faster for compression/decompression).
  mkdir -p /zstd
  cd /zstd
  wget -q -O- https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz | tar xzf -
  cd /zstd/zstd-1.5.2
  CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make zstd -j$(nproc)
  ln -s /zstd/zstd-1.5.2/zstd /usr/bin/zstd || true
  cd /zstd/zstd-1.5.2/contrib/pzstd
  CC=clang-12 CXX=clang++-12 CFLAGS="-O3" make pzstd -j$(nproc)
  rm -rf /usr/bin/pzstd || true
  ln -s /zstd/zstd-1.5.2/contrib/pzstd/pzstd /usr/bin/pzstd
}

function install_aws_cli() {
  set -euxo pipefail
  if aws --version ; then
    return # Aws cli already installed.
  fi
  temp_dir=$(mktemp -d)
  cd $temp_dir
  curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  ./aws/install
  cd /
  rm -rf $temp_dir
  ln -s /usr/local/bin/aws /usr/bin/aws
}

function install_s3pcp() {
  set -euxo pipefail
  if s3pcp --help ; then
    return # putils already installed.
  fi

  temp_dir=$(mktemp -d)
  trap 'rm -rf $temp_dir' EXIT
  cd $temp_dir

  git clone https://github.com/allada/s3pcp.git
  cd $temp_dir/s3pcp
  make s3pcp
}

function install_lighthouse() {
  set -euxo pipefail
  if lighthouse --help ; then
    return; # Lighthouse already installed.
  fi

  mkdir -p /lighthouse
  cd /lighthouse
  git clone https://github.com/sigp/lighthouse.git
  cd /lighthouse/lighthouse
  git checkout v3.2.1

  # The compile artifacts for lighthouse are large, so we create a temp zfs dataset to hold them
  # then destroy it.
  zfs destroy tank/lighthouse_target || true
  zfs create -o mountpoint=/lighthouse/lighthouse/target tank/lighthouse_target
  trap 'zfs destroy tank/lighthouse_target' EXIT

  RUSTFLAGS="-C linker=clang-12" CMAKE_ASM_COMPILER=clang-12 CC=clang-12 CXX=clang++-12 CFLAGS="-O3" \
    cargo build --release --bin lighthouse
  mv /lighthouse/lighthouse/target/release/lighthouse /usr/bin/lighthouse
}

function download_snapshot() {
  set -euxo pipefail
  zfs create -o mountpoint=none tank/lighthouse || true
  zfs create -o mountpoint=none tank/lighthouse/data || true
  zfs create -o mountpoint=/lighthouse/data/mainnet tank/lighthouse/data/mainnet || true
  mkdir -p /lighthouse/data/mainnet/beacon/
  cd /lighthouse/data/mainnet/beacon/
  s3pcp --requester-pays s3://public-blockchain-snapshots/lighthouse/mainnet/beacon/snapshot.tar.zstd - | pv | pzstd -d | tar xf -
}

function prepare_lighthouse() {
  useradd lighthouse || true

  chown -R lighthouse:lighthouse /lighthouse/

  # Stop the service if it exists.
  systemctl stop lighthouse-beacon || true

  echo "[Unit]
Description=Lighthouse beacon daemon
$( if [ "${LIGHTHOUSE_WITH_ERIGON:-}" == "1" ]; then echo 'After=erigon-eth.target'; fi )

[Service]
Type=simple
Restart=always
RestartSec=3
User=lighthouse
ExecStart=/lighthouse/start_lighthouse_beacon.sh

[Install]
WantedBy=multi-user.target
" > /etc/systemd/system/lighthouse-beacon.service

  if [ "${LIGHTHOUSE_WITH_ERIGON:-}" == "1" ]; then
    LIGHTHOUSE_ADDITONAL_FLAGS="--execution-endpoint=http://localhost:8551 --execution-jwt /erigon/data/eth/jwt.hex ${LIGHTHOUSE_ADDITONAL_FLAGS:-}"
  fi
  echo '#!/bin/bash' > /lighthouse/start_lighthouse_beacon.sh
  echo "exec lighthouse --network mainnet beacon --datadir=/lighthouse/data/mainnet ${LIGHTHOUSE_ADDITONAL_FLAGS:-}" >> /lighthouse/start_lighthouse_beacon.sh

  chmod +x /lighthouse/start_lighthouse_beacon.sh

  systemctl daemon-reload
  systemctl enable lighthouse-beacon
}

function run_lighthouse() {
  set -euxo pipefail
  systemctl start lighthouse-beacon
}

function add_create_snapshot_script() {
  set -euxo pipefail
  cat <<'EOT' > /lighthouse/create-lighthouse-snapshot.sh
#!/bin/bash
set -ex

export PATH="$PATH:/usr/sbin"

systemctl stop lighthouse-beacon

# These logs can be quite large, so delete them.
rm -rf /lighthouse/data/mainnet/beacon/logs

zfs set readonly=on tank/lighthouse/data/mainnet
cd /lighthouse/data/mainnet/beacon/
# We assume the file is alaways less than 1TB.
# At time of writing (2022-10-01) the file size is about 60gb.
one_tb=1000000000000
tar c . \
  | pzstd -3 \
  | aws s3 cp - s3://public-blockchain-snapshots/lighthouse/mainnet/beacon/snapshot.tar.zstd --expected-size=$one_tb
EOT
  chmod 0744 /lighthouse/create-lighthouse-snapshot.sh
  chown root:root /lighthouse/create-lighthouse-snapshot.sh

  echo "create-lighthouse-snapshot     /lighthouse/create-lighthouse-snapshot.sh uid=root lighthouse" >> /etc/super.tab
}

mutex_function install_prereq
mutex_function setup_drives

# Because we run our commands in a subshell we want to give cargo access to all future commands.
source "$HOME/.cargo/env"

# These installations can happen in parallel.
mutex_function install_zstd &
mutex_function install_aws_cli &
mutex_function install_s3pcp &
safe_wait # Wait for our parallel jobs finish.

mutex_function download_snapshot &
mutex_function install_lighthouse &
safe_wait # Wait for our parallel jobs finish.

mutex_function prepare_lighthouse
mutex_function run_lighthouse
mutex_function add_create_snapshot_script
