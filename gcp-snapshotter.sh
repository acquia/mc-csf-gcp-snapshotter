#!/usr/bin/env bash

# Copyright 2018 Mautic, Inc. All rights reserved
# Licensed under the MIT License (see LICENSE file for details)

set -e
#set -x

#all date operations in UTC
export TZ='UTC'

SNAPSHOT_PREFIX='gcps-'

# how many seconds earlier opposed to interval setting can we create a snapshot
INTERVAL_LEEWAY_SECONDS='3600'

# parallelism on gcloud calls
PARALLELISM=4

declare -a TIER_REGEXP
declare -a TIER_INTERVAL
declare -a TIER_PRUNING
tier_index=0

function parse_input() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --regexp)
                tier_index=$((tier_index+1))
                TIER_REGEXP[$tier_index]="$2"
                shift;shift;
            ;;
            --interval)
                TIER_INTERVAL[$tier_index]="$2"
                shift;shift;
            ;;
            --pruning)
                TIER_PRUNING[$tier_index]="$2"
                shift;shift;
            ;;
            *)
                echo "Unknown option $1" >&2
                exit 1
        esac
    done
}

function check_interval() {
    if [[ -z $1 ]]; then
        echo "You have to set the interval on all tiers including the default one"
        exit 1
    fi

    if ! date -d "now + $1" > /dev/null 2>&1; then
        echo "I cannot parse interval '$1'"
        exit 1
    fi
}
function check_pruning() {
    if [[ -z $1 ]]; then
        echo "You have to set pruning counts on all tiers including the default one"
        exit 1
    fi

    if ! [[ $1 =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "I cannot parse pruning counts '$1'"
        exit 1
    fi
}
function check_settings() {
    check_interval "${TIER_INTERVAL[0]}"
    check_pruning "${TIER_PRUNING[0]}"
    echo "Default interval is ${TIER_INTERVAL[0]}"
    echo "Default pruning is ${TIER_PRUNING[0]}"
    echo "Configured with $tier_index extra tiers"
    for i in $(seq 1 $tier_index); do
        if [[ ${TIER_INTERVAL[$i]} = "0" ]]; then
            echo "Tier $i regexp '${TIER_REGEXP[$i]}', will not be backed up"
        else
            check_interval "${TIER_INTERVAL[$i]}"
            check_pruning "${TIER_PRUNING[$i]}"
            echo "Tier $i regexp '${TIER_REGEXP[$i]}', interval '${TIER_INTERVAL[$i]}', pruning '${TIER_PRUNING[$i]}'"
        fi
    done
}

function get_disk_tier() {
    for i in $(seq 1 $tier_index); do
        if [[ $1 =~ ${TIER_REGEXP[$i]} ]]; then
            echo $i
            return 0
        fi
    done
    echo 0
}

function get_create_snapshot_command() {
    name=$(echo $1 | cut -c -33)
    hash=$(echo $1 | cut -c 34- | sha256sum | cut -c -6)
    echo "gcloud compute disks snapshot '$1' --snapshot-names='${SNAPSHOT_PREFIX}${name}-${hash}-$(date '+%Y%m%d%H%M')-$(($3 + 1))' --zone='$2' --quiet"
}

function prepare_create_snapshots() {
    disk_id="$1"
    disk_name="$2"
    zone="$3"
    tier=$(get_disk_tier "$disk_name")
    interval=${TIER_INTERVAL[$tier]}
    last_snap=$(echo "$SNAPLIST" | jq -r '.|map(select(.sourceDiskId=="'$disk_id'"))|sort_by(.creationTimestamp)|.[length-1]')
    last_snap_date=$(echo "$last_snap" |jq -r .creationTimestamp)
    last_snap_number=$(echo "$last_snap" | jq -r .name | grep -oP '[0-9]+$' || echo 0)
    echo "Processing disk $disk_name ($disk_id) in $zone in tier $tier ($interval) with last snapshot at $last_snap_date"
    if [[ $interval = "0" ]]; then
        echo "    Ignoring disk with interval 0"
        return
    fi
    if [[ $last_snap = "null" ]]; then
        echo "    Will create first snapshot"
        get_create_snapshot_command "$disk_name" "$zone" "$last_snap_number" >> $COMMAND_TEMP
        return
    fi
    if [[ $(($(date -d "$last_snap_date + $interval" '+%s') - $INTERVAL_LEEWAY_SECONDS )) -lt $(date '+%s') ]]; then
        echo "    Will create snapshot because last one is too old"
        get_create_snapshot_command "$disk_name" "$zone" "$last_snap_number" >> $COMMAND_TEMP
    else
        echo "    Not yet time for backup"
    fi
}

function reindex_snapshots() {
    index_shift=""
    while read snap; do
        number=$(echo "$snap"|grep -oP '[0-9]+$')
        if [[ -z $index_shift ]]; then
            index_shift=$(($number + 1))
            echo "1 $snap"
        else
            echo "$(( ($number - $index_shift)*-1 )) $snap"
        fi
    done
}

function generate_retention_bands() {
    index=1
    multiplier=1
    last_border=""
    while true; do
       if [[ $# -lt 1 ]]; then
          break 
       fi
       if ! [[ $index -gt $1 ]]; then
           if ! [[ -z $last_border ]]; then
               echo $last_border $(($index*$multiplier))
           fi
           last_border="$(($index*$multiplier))"
           index=$(($index+1))
       else
           shift
           multiplier=$(($multiplier*$index))
           index=1
       fi
    done
    echo "$last_border -"
}
function assign_snapshots_to_bands() {
    bands="$1"

    while read index snapname; do
        i=0
        echo "$bands" | while read low high; do
            i=$((i+1))
            if ((index >= low)) && ([[ $high = "-" ]] || ((index < high))); then
                echo -n $i
            fi
        done
        echo " $snapname"
    done
}

function prepare_delete_snapshots() {
    disk_id="$1"
    disk_name="$2"
    zone="$3"
    tier=$(get_disk_tier "$disk_name")
    pruning=$(echo ${TIER_PRUNING[$tier]}|tr , ' ')
    # ignored disks
    if [[ -z $pruning ]]; then
        return
    fi

    disk_snaps=$(echo "$SNAPLIST" | jq -r '[.[]|select(.sourceDiskId=="'$disk_id'")]|sort_by(.creationTimestamp)|reverse|.[]|.name')
    disk_snap_count=$([[ -z $disk_snaps ]] && echo 0 || echo "$disk_snaps" | wc -l)
    echo "Processing disk $disk_name ($disk_id) in $zone in tier $tier ($pruning) with $disk_snap_count snapshots"
    prepared_snapshots=$(echo "$disk_snaps" | reindex_snapshots | assign_snapshots_to_bands "$(generate_retention_bands $pruning)")
    echo "$prepared_snapshots"

    seen_index=""
    seen_snap=""
    # keep only an oldest snap in group (cannot keep newest, would lead to band stagnation)
    echo "$prepared_snapshots"| while read index snapname; do
        if [[ $seen_index = $index ]]; then
            echo "Will delete snapshot $seen_snap"
            echo "gcloud compute snapshots delete '$seen_snap' --quiet" >> $COMMAND_TEMP
        fi
        seen_index="$index"
        seen_snap="$snapname"
    done
}

function cleanup() {
    rm "$COMMAND_TEMP"
}

parse_input "$@"
check_settings
echo "Loading data from gcp"
SNAPLIST="$(gcloud compute snapshots list --format 'json' --filter "name ~ ^$SNAPSHOT_PREFIX")"
DISKLIST="$(gcloud compute disks list --format='value(id,name,zone)')"
COMMAND_TEMP=$(mktemp)
trap cleanup EXIT

echo "$DISKLIST" | while read DISK_ID DISK_NAME ZONE; do prepare_create_snapshots "$DISK_ID" "$DISK_NAME" "$ZONE"; done

cat $COMMAND_TEMP | xargs -L1 -P$PARALLELISM -I'{}' bash -c '{}'

echo "Loading fresh snapshotlist from gcp"
SNAPLIST="$(gcloud compute snapshots list --format 'json' --filter "name ~ ^$SNAPSHOT_PREFIX")"
: > $COMMAND_TEMP

echo "$DISKLIST" | while read DISK_ID DISK_NAME ZONE; do prepare_delete_snapshots "$DISK_ID" "$DISK_NAME" "$ZONE"; done

cat $COMMAND_TEMP | xargs -L1 -P$PARALLELISM -I'{}' bash -c '{}'

echo Finished
