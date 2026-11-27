/*
 * Copyright 2022 balena.io
 *
 * Licensed under the Apache License, Vrsion 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

'use strict'

const _ = require('lodash')
const fs = require('fs-extra')
const path = require('path')
const contrato = require('@balena/contrato')
const yaml = require('js-yaml')
const requireAll = require('require-all')

const BUILD_DIR = path.join(__dirname, '../../../build')
const DEST_DIR = path.join(BUILD_DIR, 'contracts')
const BLUEPRINT_PATHS = {
  'os-contracts': path.join(__dirname, 'blueprints/os-contracts.yaml'),
}
const CONTRACTS_PATH = path.join(BUILD_DIR, '../contracts/contracts')
const PRIVATE_CONTRACTS_PATH = path.join(BUILD_DIR, '../private-contracts/contracts')

const contractsPaths = []
if ( fs.pathExistsSync(CONTRACTS_PATH) ) {
  contractsPaths.push(CONTRACTS_PATH)
} else {
  console.log(`${CONTRACTS_PATH} must exist and contain contracts`)
  process.exit(1)
}
if ( fs.pathExistsSync(PRIVATE_CONTRACTS_PATH) ) {
  contractsPaths.push(PRIVATE_CONTRACTS_PATH)
}

if ( contractsPaths.length === 0 ) {
    console.log(`${CONTRACTS_PATH} must exist and contain contracts`)
    process.exit(1)
}

const blueprints = _.mapValues(BLUEPRINT_PATHS, (blueprintPath) => {
  return yaml.safeLoad(fs.readFileSync(blueprintPath, 'utf8'))
})

// Load only the contract types that the blueprints select. Other types
// (e.g. sw.stack, sw.blob) can fail contrato's schema validation.
const contractTypes = _.uniq(_.flatMap(blueprints, (blueprint) => Object.keys(blueprint.selector)))

// Create universe of contracts
const universe = new contrato.Contract({
  type: 'meta.universe'
})
for (const contractPath of contractsPaths) {
  for (const type of contractTypes) {
    const typePath = path.join(contractPath, type)
    if (!fs.pathExistsSync(typePath)) {
      continue
    }

    const allContracts = requireAll({
      dirname: typePath,
      filter: /.json$/,
      recursive: true,
      resolve: (json) => {
        return contrato.Contract.build(json)
      }
    })

    universe.addChildren(_.flattenDeep(_.map(_.values(allContracts), _.values)))
  }
}

// Remove the operating systems that are not balenaOS
const unwantedOS = ['alpine','debian','ubuntu','fedora','resinos']
unwantedOS.forEach( (slug) => {
  const children = universe.findChildren(contrato.Contract.createMatcher({
    type: 'sw.os',
    slug: slug
  }))

  children.forEach((child) => {
    universe.removeChild(child)
  })
})

const generate = async () => {
  for (const query of Object.values(blueprints)) {
    // contrato.query() returns an iterator, not an array
    const result = [...contrato.query(universe, query.selector, query.output)]

    const template = query.output.template[0].data

    for (const context of result) {
      const json = context.toJSON()
      const destination = path.join(
        DEST_DIR,
        json.path,
        query.output.filename
      )

      console.log(`Generating ${json.imageName}`)
      fs.outputFileSync(destination, await contrato.buildTemplate(template, json, {
        directory: CONTRACTS_PATH
      }))
    }

    console.log(`Generated ${result.length} results out of ${universe.getChildren().length} contracts`)
  }
}

generate().catch((err) => {
  console.error(err)
  process.exit(1)
})
