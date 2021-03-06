#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

# common functions used by postgres backup scripts
echo ""   # blank line in log file helps scroll btwn instances
source /root/.bashrc # source in the manta configs such as the url and credentials
export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o xtrace
set -o pipefail

PATH=/opt/smartdc/manatee/node_modules/.bin:/opt/smartdc/manatee/build/node/bin:/opt/local/bin:/usr/sbin/:/usr/bin:/usr/sbin:/usr/bin:/opt/smartdc/registrar/build/node/bin:/opt/smartdc/manatee/node_modules/.bin:/opt/smartdc/registrar/node_modules/.bin:/opt/smartdc/manatee/lib/tools:/opt/smartdc/manatee/pg_dump/

FATAL=
CFG=/opt/smartdc/manatee/etc/backup.json
DATASET=
DATE=
DUMP_DATASET=
DUMP_DIR=
MANATEE_LOCK="manatee-adm check-lock"
MANATEE_STAT=manatee-stat
MANTA_DIR_PREFIX=/poseidon/stor/manatee_backups
MMKDIR=mmkdir
MPUT=mput
MY_IP=
LOCK_PATH=/pg_dump_lock
PG_DIR=
PG_DIR_SIZE=
PG_PID=
SHARD_NAME=
PG_START_TIMEOUT=$2 || 10
PG_START_MAX_TRIES=50
PG_START_TRIES=0
UPLOAD_SNAPSHOT=
ZFS_CFG=/opt/smartdc/manatee/etc/snapshotter.json
ZFS_SNAPSHOT=$1
ZK_IP=

function onexit
{
    graceful_cleanup
}
trap onexit EXIT

function fatal
{
    FATAL=1
    echo "$(basename $0): fatal error: $*"
    graceful_cleanup || true # for errexit
    exit 1
}

function check_lock
{
    $MANATEE_LOCK -p $LOCK_PATH -z $ZK_IP
    [[ $? -eq 0 ]] || fatal "lock either exists or unable to check lock"
}

function take_zfs_snapshot
{
    echo "take a snapshot"
    ZFS_SNAPSHOT=$DATASET@$(date +%s)000
    zfs snapshot $ZFS_SNAPSHOT
    [[ $? -eq 0 ]] || fatal "Unable to create a snapshot"
}

function upload_zfs_snapshot
{
    # only upload the snapshot if the flag is set
    if [[ $UPLOAD_SNAPSHOT -eq 1 ]]; then
        local snapshot_size=$(zfs list -Hp -o refer -t snapshot $ZFS_SNAPSHOT)
        [[ $? -eq 0 ]] || return "Unable to retrieve snapshot size"
        # pad the snapshot_size by 5% since there's some zfs overhead, note the
        # last bit just takes the floor of the floating point value
        local snapshot_size=$(echo "$snapshot_size * 1.05" | bc | cut -d '.' -f1)
        [[ -n "$snapshot_size" ]] || return "Unable to calculate snapshot size"
        local dir=$MANTA_DIR_PREFIX/$SHARD_NAME/$(date -u +%Y/%m/%d/%H)
        $MMKDIR -p -u $MANTA_URL -a $MANTA_USER -k $MANTA_KEY_ID $dir
        [[ $? -eq 0 ]] || return "unable to create backup dir"
        echo "sending snapshot $ZFS_SNAPSHOT to manta"
        local snapshot_manta_name=$(echo $ZFS_SNAPSHOT | gsed -e 's|\/|\-|g')
        zfs send $ZFS_SNAPSHOT | $MPUT $dir/$snapshot_manta_name -H "max-content-length: $snapshot_size"
        [[ $? -eq 0 ]] || return "unable to send snapshot $ZFS_SNAPSHOT"

        echo "successfully backed up snapshot $ZFS_SNAPSHOT to manta file $dir/$snapshot_manta_name"
    fi

    return 0
}

function mount_data_set
{
    # destroy the dump dataset if it already exists
    zfs destroy -R $DUMP_DATASET
    # clone the current snapshot. Disable sync for faster performance.
    zfs clone -o sync=disabled $ZFS_SNAPSHOT $DUMP_DATASET
    [[ $? -eq 0 ]] || fatal "unable to clone snapshot"
    echo "successfully mounted dataset"
    # remove recovery.conf so this pg instance does not become a slave
    rm -f $PG_DIR/recovery.conf
    # remove postmaster.pid
    rm -f $PG_DIR/postmaster.pid
    # get pg dir size
    PG_DIR_SIZE=$(du -s $PG_DIR | cut -f1)

    ctrun -o noorphan sudo -u postgres postgres -D $PG_DIR -p 23456 \
        -c logging_collector=off -c fsync=off -c synchronous_commit=off \
        -c checkpoint_segments=100 -c checkpoint_timeout=1h &
    PG_PID=$!
    [[ $? -eq 0 ]] || fatal "unable to start postgres"

    wait_for_pg_start
}

function wait_for_pg_start
{
    echo "waiting $PG_START_TIMEOUT seconds for PG to start"
    PG_START_TRIES=$(($PG_START_TRIES + 1))
    if [[ $PG_START_TRIES -gt $PG_START_MAX_TRIES ]]; then
        fatal "PG start tries exceeded, did not start in time"
    fi
    sleep $PG_START_TIMEOUT
    # check and see if pg is up.
    sudo -u postgres psql -p 23456 moray -c 'select current_time'
    if [[ $? -eq 0 ]]; then
        echo "PG has started"
    else
        echo "PG not started yet, waiting again"
        wait_for_pg_start
    fi
}

# $1 optional, dictates whether to backup the moray DB
function backup ()
{
    local date
    if [[ -z "$DATE" ]]; then
        date=$(date -u +%Y-%m-%d-%H)
    else
        date=$DATE
    fi
    # Dump the db to the same dataset. Since the dataset is configured to use
    # sync=disabled, this will be faster than writing to /var/tmp
    DUMP_DIR=/$DUMP_DATASET/$(uuid)
    mkdir -p $DUMP_DIR

    if [[ "$1" == "JSON" ]]; then
        echo "getting db tables"
        schema=$DUMP_DIR/$date'_schema'
        # trim the first 3 lines of the schema dump
        sudo -u postgres psql -p 23456 moray -c '\dt' | sed -e '1,3d' > $schema
        [[ $? -eq 0 ]] || (rm $schema; fatal "unable to read db schema")
        for i in `sed 'N;$!P;$!D;$d' $schema | tr -d ' '| cut -d '|' -f2`
        do
            local time=$(date -u +%F-%H-%M-%S)
            local dump_file=$DUMP_DIR/$date'_'$i-$time.gz
            sudo -u postgres pg_dump -p 23456 moray -a -t $i | gsed 's/\\\\/\\/g' | sqlToJson.js | gzip -1 > $dump_file
            [[ $? -eq 0 ]] || fatal "Unable to dump table $i"
        done
        rm $schema
        [[ $? -eq 0 ]] || fatal "unable to remove schema"
    fi
    if [[ "$1" ==  "DB" ]]; then
        echo "dumping moray db"
        # dump the entire moray db as well for manatee backups.
        local time=$(date -u +%F-%H-%M-%S)
        full_dump_file=$DUMP_DIR/$date'_'moray-$time.gz
        sudo -u postgres pg_dump -p 23456 moray | gzip -1 > $full_dump_file
        [[ $? -eq 0 ]] || fatal "Unable to dump full moray db"
    fi
}

function upload_pg_dumps
{
    local upload_error=0;
    for f in $(ls $DUMP_DIR); do
        local year=$(echo $f | cut -d _ -f 1 | cut -d - -f 1)
        local month=$(echo $f | cut -d _ -f 1 | cut -d - -f 2)
        local day=$(echo $f | cut -d _ -f 1 | cut -d - -f 3)
        local hour=$(echo $f | cut -d _ -f 1 | cut -d - -f 4)
        local name=$(echo $f | cut -d _ -f 2-)
        local dir=$MANTA_DIR_PREFIX/$SHARD_NAME/$year/$month/$day/$hour
        $MMKDIR -p $dir
        if [[ $? -ne 0 ]]; then
            echo "unable to create backup dir"
            upload_error=1
            continue;
        fi
        echo "uploading dump $f to manta"
        $MPUT -H "m-pg-size: $PG_DIR_SIZE" -f $DUMP_DIR/$f $dir/$name
        if [[ $? -ne 0 ]]; then
            echo "unable to upload dump $DUMP_DIR/$f"
            upload_error=1
        else
            echo "removing dump $DUMP_DIR/$f"
            rm $DUMP_DIR/$f
        fi
    done

    return $upload_error
}

function get_self_role
{
    # s/./\./ to 1.moray.us.... for json
    read -r shard_name_delim< <(echo $SHARD_NAME | gsed -e 's|\.|\\.|g')

    # figure out if we are the peer that should perform backups.
    local shard_info=$($MANATEE_STAT $ZK_IP:2181 -s $SHARD_NAME)
    [[ -n $shard_info ]] || fatal "Unable to retrieve shardinfo from zookeeper"

    local async=$(echo $shard_info | json $shard_name_delim.async.ip)
    [[ -n $async ]] || echo "warning: unable to parse async peer"
    local sync=$(echo $shard_info | json $shard_name_delim.sync.ip)
    [[ -n $sync ]] || echo "warning: unable to parse sync peer"
    local primary=$(echo $shard_info | json $shard_name_delim.primary.ip)
    [[ -n $primary ]] || fatal "unable to parse primary peer"

    local continue_backup=0
    if [ "$async" = "$MY_IP" ]; then
        continue_backup=1
    elif [[ -z "$async"  &&  "$sync" = "$MY_IP" ]]; then
        continue_backup=1
    elif [[ -z "$sync"  &&  -z "$async"  &&  "$primary" = "$MY_IP" ]]; then
        continue_backup=1
    elif [ -z "$sync" ] && [ -z "$async" ]; then
        fatal "not primary but async/sync dne, exiting 1"
    fi

    return $continue_backup
}

#
# cleanup() is the function that various pg_dump scripts call prior to normal,
# successful exit in order to kill postgres and destroy the temporary ZFS
# dataset that we created.  If the cleanup itself fails, then we should exit the
# program with a non-zero status.
#
function cleanup
{
    graceful_cleanup || fatal "unable to clean up"
}

#
# graceful_cleanup() attempts to shut down the postgres instance as quickly as
# possible and then destroy the dump dataset that we've created.  To deal with
# bugs that result in being unable to destroy the ZFS dataset (either
# transiently or for an extended period), we keep trying to destroy the dataset
# until either that succeeds or we discover that it's gone.  If we find it takes
# more than one attempt, we attempt to use "fuser" to identify the culprits for
# later debugging.
#
# This function has nothing (directly) to do with exiting this script.  It must
# not call fatal(), since fatal() invokes this function to clean up.  If the
# caller wants to exit, or to call fatal() themselves, they may do so.
#
function graceful_cleanup
{
    local dci sleeptime nattempts

    if [[ -n "$PG_PID" ]] && ! kill -9 $PG_PID; then
        echo "warn: failed to send SIGKILL to pid $PG_PID"
    fi

    if [[ -z "$DUMP_DATASET" ]]; then
        echo "warn: DUMP_DATASET is empty"
        return 0
    fi

    sleeptime=1
    nattempts=10
    for (( dci = 0; dci < nattempts; dci++ )); do
        if zfs destroy -R $DUMP_DATASET; then
            return 0;
        fi

        if ! zfs list $DUMP_DATASET > /dev/null; then
            echo "failed to destroy \"$DUMP_DATASET\", but also" \
                "failed to list it (assuming destroyed)"
            return 0;
        fi

        echo "failed to destroy $DUMP_DATASET (will retry)"
        echo "active users:"
        if ! fuser -c "$(zfs list -H -o mountpoint $DUMP_DATASET)" 2>&1; then
            echo "warn: failed to list active users"
        fi
        sleep $sleeptime
    done

    echo "failed to destroy $DUMP_DATASET (gave up after $nattempts tries)"
    return 1
}
