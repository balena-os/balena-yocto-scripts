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

// Create universe of contracts
const universe = new contrato.Contract({
  type: 'meta.universe'
})
contractsPaths.forEach( (contractPath) => {
  // Find and build all contracts from the contracts/ directory
  const allContracts = requireAll({
    dirname: contractPath,
    filter: /.json$/,
    recursive: true,
    resolve: (json) => {
      return contrato.Contract.build(json)
    }
  })

  const contracts = _.reduce(_.values(allContracts), (accumulator, value) => {
    return _.concat(accumulator, _.flattenDeep(_.map(_.values(value), _.values)))
  }, [])

  universe.addChildren(contracts)
})

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

let blueprints = Object.keys(BLUEPRINT_PATHS)

for (const type of blueprints) {
  if (!BLUEPRINT_PATHS[type]) {
    console.error(`Blueprint for this device type: ${type} is missing!`)
    process.exit(1)
  }

  const query = yaml.safeLoad(fs.readFileSync(BLUEPRINT_PATHS[type], 'utf8'))

  // Execute query
  const result = contrato.query(universe, query.selector, query.output)

  // Get templates
  const template = query.output.template[0].data

  // Write output
  for (const context of result) {
    const json = context.toJSON()
    const destination = path.join(
      DEST_DIR,
      json.path,
      query.output.filename
    )

    console.log(`Generating ${json.imageName}`)
    fs.outputFileSync(destination, contrato.buildTemplate(template, context, {
      directory: CONTRACTS_PATH
    }))
  }

  console.log(`Generated ${result.length} results out of ${universe.getChildren().length} contracts`)
}
