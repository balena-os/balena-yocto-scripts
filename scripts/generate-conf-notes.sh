#!/bin/bash

#
# conf-notes.txt generator
# ------------------------
#
# Signed-off-by: Theodor Gherzan <theodor@resin.io>
# Signed-off-by: Andrei Gherzan <andrei@resin.io>
#

CONF=$1             # CONFNAME file directory location
JSON=$2             # JSON file full path
YOCTO_VERSION=$3    # Yocto version used
CONFNAME="conf-notes.txt"

# The conf directory is yocto version specific
CONF=$CONF/samples

# Checks
if [ $# -ne 3 ] || ! `which jq > /dev/null 2>&1` || [ ! -f $JSON ] || [ -z $CONF ] || [ ! -d $CONF ]; then
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
for target in `cat $JSON | jq  -r '[.[].yocto.image] | unique | sort | .[] | select( . != null)'`; do
    echo "    $target" >> $CONF/$CONFNAME
done
echo >> $CONF/$CONFNAME

for machine in `jq -r ".[] | select(.yocto.version == \"$YOCTO_VERSION\") | [.yocto.machine] | sort | .[] | select(. != null)" $JSON`; do
    NAME=`cat $JSON | jq  -r '.[] | select(.yocto.machine == '\"${machine}\"').name'`
    MACHINE=`cat $JSON | jq  -r '.[].yocto | select(.machine == '\"${machine}\"').machine'`
    IMAGE=`cat $JSON | jq  -r '.[].yocto | select(.machine == '\"${machine}\"').image'`
    printf "%-30s : %s\n" "$NAME" "\$ MACHINE=$MACHINE bitbake $IMAGE" >> $CONF/$CONFNAME
done
echo >> $CONF/$CONFNAME
