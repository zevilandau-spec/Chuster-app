#!/bin/sh
# Build the app data from one export folder.  Usage: sh build_from.sh <export_dir> <out_data.json> <as_of YYYY-MM-DD> <from YYYY-MM-DD> [prev_to]
set -e
T=$(cd "$(dirname "$0")" && pwd)
E=$1; OUT=$2; ASOF=$3; FROM=$4; PREV=${5:-$3}
CHUSTER_SOURCE="QuickBooks, $ASOF" CHUSTER_FROM=$FROM CHUSTER_PREV_TO=$PREV CHUSTER_AS_OF=$ASOF python3 -I $T/build_data.py $E $OUT | head -1
python3 -I $T/build_pack.py $E/loose.csv $E/packed.csv $OUT | head -1
python3 -I $T/build_buy.py $E/purchases_all.csv $E $OUT | head -1
python3 -I $T/build_orders.py $E $OUT 120 | tail -1
python3 -I $T/build_items.py $E $OUT | tail -1
python3 -I $T/build_reps.py $E $OUT | tail -1
python3 -I $T/build_hist.py $E $OUT | tail -1
python3 -I $T/build_fin.py $E $OUT $ASOF | tail -1
python3 -I $T/build_daily.py $E $OUT | tail -1
