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
    echo -e "./generate-conf-notes.sh ./path/to/meta-resin-<target>/conf/ <json1> <json2> ...\n"
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
  _____           _         _       
 |  __ \         (_)       (_)      
 | |__) |___  ___ _ _ __    _  ___  
 |  _  // _ \/ __| | '_ \  | |/ _ \ 
 | | \ \  __/\__ \ | | | |_| | (_) |
 |_|  \_\___||___/_|_| |_(_)_|\___/ 
                                    
 ---------------------------------- \n" > $CONF/$CONFNAME

echo "Resin specific targets are:" >> $CONF/$CONFNAME
for json in "${@:2}"; do
    IMAGE=`cat $json | jq  -r '.yocto.image | select( . != null)'`
    if [ -z $IMAGE ]; then
        continue
    fi
    echo "    $IMAGE" >> $CONF/$CONFNAME
    echo >> $CONF/$CONFNAME
    NAME=`cat $json | jq  -r '.name'`
    MACHINE=`cat $json | jq  -r '.yocto.machine'`
    printf "%-30s : %s\n" "$NAME" "\$ MACHINE=$MACHINE bitbake $IMAGE" >> $CONF/$CONFNAME
done
echo >> $CONF/$CONFNAME
