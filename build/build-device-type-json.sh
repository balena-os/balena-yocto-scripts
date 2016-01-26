#!/bin/bash

# Usage:
# ./build-device-type-json.sh ./path/to/device-type-folder/device-type-slug.coffee
# this generates ./path/to/device-type-folder/device-type-slug.json

mydir=`dirname $0`

for filename in *.coffee; do
    slug="${filename%.*}"
    cd $mydir/../../
    npm install coffee-script --production
    cd ./resin-device-types && npm install --production && cd ..

NODE_PATH=. node > $slug.json << EOF
    require('coffee-script/register');
    var dt = require('resin-device-types');
    var manifest = require('./${filename}');
    var slug = '${slug}';
    var builtManifest = dt.buildManifest(manifest, slug);
    console.log(JSON.stringify(builtManifest, null, '\t'));
EOF
done

echo "Done"
