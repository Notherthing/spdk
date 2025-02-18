#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2022 Intel Corporation
#  All rights reserved.
#

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../..)
source $rootdir/test/common/autotest_common.sh
source $testdir/common.sh

rpc_py=$rootdir/scripts/rpc.py

fio_kill() {
	rm -f $testdir/testfile.md5
	rm -f $testdir/config/ftl.json
	rm -f $testdir/random_pattern
	rm -f $file

	killprocess $svcpid
}

device=$1
cache_device=$2
timeout=240
data_size_in_blocks=$((65536))
unmap_size_in_blocks=$((1024))

if [[ $CONFIG_FIO_PLUGIN != y ]]; then
	echo "FIO not available"
	exit 1
fi

export FTL_BDEV_NAME=ftl0
export FTL_JSON_CONF=$testdir/config/ftl.json

trap "fio_kill; exit 1" SIGINT SIGTERM EXIT

"$SPDK_BIN_DIR/spdk_tgt" -m 0x7 &
svcpid=$!
waitforlisten $svcpid

split_bdev=$(create_base_bdev nvme0 $device $((1024 * 101)))
nv_cache=$(create_nv_cache_bdev nvc0 $cache_device $split_bdev)

l2p_percentage=60
l2p_dram_size_mb=$(($(get_bdev_size $split_bdev) * l2p_percentage / 100 / 1024))

$rpc_py -t $timeout bdev_ftl_create -b ftl0 -d $split_bdev -c $nv_cache --core_mask 7 --l2p_dram_limit $l2p_dram_size_mb --overprovisioning 10

waitforbdev ftl0

(
	echo '{"subsystems": ['
	$rpc_py save_subsystem_config -n bdev
	echo ']}'
) > $FTL_JSON_CONF

bdev_info=$($rpc_py bdev_get_bdevs -b ftl0)
nb=$(jq ".[] .num_blocks" <<< "$bdev_info")

killprocess $svcpid

# Generate data pattern
dd if=/dev/urandom bs=4K count=$data_size_in_blocks > $testdir/random_pattern

# Write data pattern
"$SPDK_BIN_DIR/spdk_dd" --if=$testdir/random_pattern --ob=ftl0 --json=$FTL_JSON_CONF

"$SPDK_BIN_DIR/spdk_tgt" -L ftl_init &
svcpid=$!
waitforlisten $svcpid

$rpc_py load_config < $FTL_JSON_CONF

# Unmap first and last 4MiB
$rpc_py bdev_ftl_unmap -b ftl0 --lba 0 --num_blocks $((unmap_size_in_blocks))
$rpc_py bdev_ftl_unmap -b ftl0 --lba $((nb - unmap_size_in_blocks)) --num_blocks $((unmap_size_in_blocks))

killprocess $svcpid

# Calculate checksum of the data written
file=$testdir/data
"$SPDK_BIN_DIR/spdk_dd" --ib=ftl0 --of=$file --count=$data_size_in_blocks --json=$FTL_JSON_CONF
cmp --bytes=$((unmap_size_in_blocks * 4096)) $file /dev/zero
md5sum $file > $testdir/testfile.md5

# Rewrite the first 4MiB
"$SPDK_BIN_DIR/spdk_dd" --if=$testdir/random_pattern --ob=ftl0 --count=$((unmap_size_in_blocks)) --json=$FTL_JSON_CONF

"$SPDK_BIN_DIR/spdk_tgt" -L ftl_init &
svcpid=$!
waitforlisten $svcpid

$rpc_py load_config < $FTL_JSON_CONF

# Unmap first and last 4MiB
$rpc_py bdev_ftl_unmap -b ftl0 --lba 0 --num_blocks $((unmap_size_in_blocks))
$rpc_py bdev_ftl_unmap -b ftl0 --lba $((nb - unmap_size_in_blocks)) --num_blocks $((unmap_size_in_blocks))

killprocess $svcpid

# Verify that the checksum matches and the data is consistent
"$SPDK_BIN_DIR/spdk_dd" --ib=ftl0 --of=$file --count=$data_size_in_blocks --json=$FTL_JSON_CONF
md5sum -c $testdir/testfile.md5

trap - SIGINT SIGTERM EXIT
fio_kill
