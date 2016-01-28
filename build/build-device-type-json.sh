#!/bin/bash

# Usage:
# ./build-device-type-json.sh
# this generates device-type-slug.json in the root of the resin-<board> directory

mydir=`dirname $0`

cd $mydir/../../

for filename in *.coffee; do
    slug="${filename%.*}"
    npm install coffee-script --production
    cd ./resin-device-types && npm install --production && cd ..

NODE_PATH=. node > "$slug".json << EOF
    require('coffee-script/register');
    var dt = require('resin-device-types');
    var manifest = require('./${filename}');
    var slug = '${slug}';
    var builtManifest = dt.buildManifest(manifest, slug);
    console.log(JSON.stringify(builtManifest, null, '\t'));
EOF
done
