#!/bin/bash

# Usage:
# ./build-device-type-json.sh ./path/to/device-type-folder/device-type-slug.coffee
# this generates ./path/to/device-type-folder/device-type-slug.json

mydir=`dirname $0`
filedir=`dirname $1`
filename=`basename $1`
extension="${filename##*.}"
slug="${filename%.*}"

cp $mydir/manifest-package.json $filedir/package.json
cd $filedir
npm install --production

node > $slug.json << EOF
    require('coffee-script/register');
    var dt = require('resin-device-types');
    var manifest = require('./${filename}');
    var slug = '${slug}';
    var builtManifest = dt.buildManifest(manifest, slug);
    console.log(JSON.stringify(builtManifest, null, '\t'));
EOF

echo "Done"
