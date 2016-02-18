#!/bin/bash

# Usage:
# ./build-device-type-json.sh
# this generates device-type-slug.json in the root of the resin-<board> directory

mydir=`dirname $0`

cd $mydir/../../

function quit {
    rm -f "$slug".json
    echo $0: $1 >&2
    exit 1
}

for filename in *.coffee; do
    slug="${filename%.*}"
    npm install coffee-script --production 2>/dev/null || quit "ERROR - Please install the 'npm' package before running this script."
    cd ./resin-device-types && npm install --production && cd ..

{ NODE_PATH=. node > "$slug".json 2>/dev/null << EOF
    require('coffee-script/register');
    var dt = require('resin-device-types');
    var manifest = require('./${filename}');
    var slug = '${slug}';
    var builtManifest = dt.buildManifest(manifest, slug);
    console.log(JSON.stringify(builtManifest, null, '\t'));
EOF
} || quit "ERROR - Please install the 'nodejs' package before running this script."

if [ ! -s "$slug".json ]; then
    quit "ERROR - Please check your nodejs installation. The 'node' binary did not generate proper .json(s)."
fi

done
