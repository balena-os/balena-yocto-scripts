#!/bin/bash

#
# conf-notes.txt generator
# ------------------------
#
# Signed-off-by: Theodor Gherzan <theodor@resin.io>
# Signed-off-by: Andrei Gherzan <andrei@resin.io>
# Signed-off-by: Florin Sarbu <florin@resin.io>
#

CONF=$1             # CONFNAME file directory location
CONFNAME="conf-notes.txt"

# The conf directory is yocto version specific
CONF=$CONF/samples

# Checks

if [ $# -lt 2 ]; then
    echo -e 'Usage:\n'
    echo -e "./generate-conf-notes.sh ./path/to/meta-balena-<target>/conf/ <json1> <json2> ...\n"
    exit 0
fi

for json in "${@:2}"; do
    if [ ! -f $json ]; then
      echo -e "File $json does not exist. Exiting!\n"
      exit 1
    fi
done

if ! `which jq > /dev/null 2>&1` || [ -z $CONF ] || [ ! -d $CONF ]; then
    exit 1
fi

echo -e "
  _           _                   ___  ____
 | |__   __ _| | ___ _ __   __ _ / _ \/ ___|
 | '_ \ / _\` | |/ _ \ '_ \ / _\` | | | \___ \\
 | |_) | (_| | |  __/ | | | (_| | |_| |___) |
 |_.__/ \__,_|_|\___|_| |_|\__,_|\___/|____/

 -------------------------------------------- \n" > $CONF/$CONFNAME

IMAGES=""
BOARDS_COMMANDS=""

for json in "${@:2}"; do
    IMAGE=`jq -r '.yocto.image | select( . != null)' $json`
    IMAGES="$IMAGES $IMAGE"
    NAME=`jq -r '.name' $json`
    MACHINE=`jq -r '.yocto.machine' $json`
    BOARD_COMMAND=$(printf "%-40s : %s\n" "$NAME" "\$ MACHINE=$MACHINE bitbake $IMAGE")
    if [ -z "$BOARDS_COMMANDS" ]; then
        BOARDS_COMMANDS="$BOARD_COMMAND"
    else
        BOARDS_COMMANDS="$BOARDS_COMMANDS\n$BOARD_COMMAND"
    fi
done

# Unique images
IMAGES=`echo $IMAGES | tr ' ' '\n' | sort -u`

# Write conf file
echo "Resin specific images available:" >> $CONF/$CONFNAME
for image in $IMAGES; do
    echo -e "\t$image" >> $CONF/$CONFNAME
done
echo >> $CONF/$CONFNAME
echo -e "$BOARDS_COMMANDS" >> $CONF/$CONFNAME
echo >> $CONF/$CONFNAME
