#!/bin/bash

# Usage:
# ./build-device-type-json.sh
# this generates device-type-slug.json in the root of the resin-<board> directory

mydir=`dirname $0`

cd $mydir/../../

for filename in *.coffee; do
    slug="${filename%.*}"
    npm install coffee-script --production 2>/dev/null || { echo "Error - Please install the 'npm' package before running this script." >&2; exit 1; }
    cd ./resin-device-types && npm install --production && cd ..

{ NODE_PATH=. node > "$slug".json 2>/dev/null << EOF
    require('coffee-script/register');
    var dt = require('resin-device-types');
    var manifest = require('./${filename}');
    var slug = '${slug}';
    var builtManifest = dt.buildManifest(manifest, slug);
    console.log(JSON.stringify(builtManifest, null, '\t'));
EOF
} || { echo "Error - Please install the 'nodejs' package before running this script." >&2; rm "$slug".json; exit 1; }
done
