#!/bin/bash

# Usage:
# ./build-device-type-json.sh [directory]
# this generates device-type-slug.json in the root of the resin-<board> directory
# the directory can be passed as an optional argument, default is 2 levels higher than the script itself

mydir=`dirname $0`
rootdir=${1:-$mydir/../../}

cd $rootdir

rm -f *.json

function quit {
    rm -f "$slug".json
    echo $0: $1 >&2
    exit 1
}

(cd ./resin-device-types && npm install --production 1>/dev/null || quit "ERROR - Please install the 'npm' package before running this script.")

for filename in *.coffee; do
    slug="${filename%.*}"

{ NODE_PATH=. node > "$slug".json 2>/dev/null << EOF
    require('resin-device-types/node_modules/coffee-script/register');
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

echo "Done"
