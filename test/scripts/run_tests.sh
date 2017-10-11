#!/usr/bin/env bash

export WSK=${WSK-wsk}
export CF=${CF-cf}

echo "Running Convo-Flexible-Bot test suite."

CLOUDANT_URL=''
CLOUDANT_AUTH_DBNAME='authdb'
CLOUDANT_CONTEXT_DBNAME='contextdb'
AUTH_DOC=''
RETCODE=0

### MAIN
main() {
  loadEnvVars
  processCfLogin
  changeWhiskKey
  createCloudantInstanceDatabases
  createWhiskArtifacts
  setupTestArtifacts
  runTestSuite
  destroyTestArtifacts
  destroyWhiskArtifactsAndDatabases
  echo 'Done.'
}

### Loads the test environment variables
loadEnvVars() {
  echo 'Loading env variables from test/resources/.env'
  # Read the master test creds file.
  export $(cat test/resources/.env | xargs)
}

### CHECK OR PROCESS CF LOGIN
processCfLogin() {
  echo 'Logging into Bluemix using cf...'
  #Login to Bluemix
  if [ -n ${__TEST_BX_CF_KEY} ]; then
    ${CF} login -a ${__TEST_BX_API_HOST} -u apikey -p ${__TEST_BX_CF_KEY} -o ${__TEST_BX_USER_ORG} -s ${__TEST_BX_USER_SPACE}
  else
    echo 'CF not logged in, and missing ${__TEST_BX_CF_KEY}'
    exit 1
  fi
}

# Switches the Openwhisk namespace based on the current Bluemix org/space
# where user has logged in.
changeWhiskKey() {
  echo 'Syncing wsk namespace with CF namespace...'
  WSK_NAMESPACE="`${CF} target | grep 'Org:' | awk '{print $2}'`_`${CF} target | grep 'Space:' | awk '{print $2}'`"
  if [ "${WSK_NAMESPACE}" == `${WSK} namespace list | tail -n +2 | head -n 1` ]; then
    return
  fi
  TARGET=`${CF} target | grep 'API endpoint:' | awk '{print $3}'`
  WSK_API_HOST="https://openwhisk.${TARGET#*.}"

  ACCESS_TOKEN=`cat ~/.cf/config.json | jq -r .AccessToken | awk '{print $2}'`
  REFRESH_TOKEN=`cat ~/.cf/config.json | jq -r .RefreshToken`

  WSK_CREDENTIALS=`curl -s -X POST -H 'Content-Type: application/json' -d '{"accessToken": "'$ACCESS_TOKEN'", "refreshToken": "'$REFRESH_TOKEN'"}' ${WSK_API_HOST}/bluemix/v2/authenticate`
  WSK_API_KEY=`echo ${WSK_CREDENTIALS} | jq -r ".namespaces[] | select(.name==\"${WSK_NAMESPACE}\") | [.uuid, .key] | join(\":\")"`

  ${WSK} property set --apihost ${WSK_API_HOST} --auth "${WSK_API_KEY}" --namespace ${WSK_NAMESPACE}
}

### CHECK OR CREATE CLOUDANT-LITE DATABASE INSTANCE, CREATE AUTH DATABASE
createCloudantInstanceDatabases() {
  echo 'Checking for or creating cloudant instance...'
  CLOUDANT_INSTANCE_NAME='convoflex'
  CLOUDANT_INSTANCE_KEY='bot-key'

  ${CF} service ${CLOUDANT_INSTANCE_NAME} > /dev/null
  if [ "$?" != "0" ]; then
    ${CF} create-service cloudantNoSQLDB Lite convoflex
  fi
  ${CF} service-key ${CLOUDANT_INSTANCE_NAME} ${CLOUDANT_INSTANCE_KEY} > /dev/null
  if [ "$?" != "0" ]; then
    ${CF} create-service-key ${CLOUDANT_INSTANCE_NAME} ${CLOUDANT_INSTANCE_KEY}
  fi
  CLOUDANT_URL=`${CF} service-key ${CLOUDANT_INSTANCE_NAME} ${CLOUDANT_INSTANCE_KEY} | tail -n +2 | jq -r .url`

  for i in {1..10}; do
    e=`curl -s -XPUT ${CLOUDANT_URL}/${CLOUDANT_AUTH_DBNAME} | jq -er .error`
    if [ "$?" == "0" ]; then
      if [ "$e" == "conflict" -o "$e" == "file_exists" ]; then
        break
      fi
      echo "create auth database returned with error [$e], retrying..."
      sleep 5
    else
      break
    fi
  done

  for i in {1..10}; do
    e=`curl -s -XPUT ${CLOUDANT_URL}/${CLOUDANT_CONTEXT_DBNAME} | jq -er .error`
    if [ "$?" == "0" ]; then
      if [ "$e" == "conflict" -o "$e" == "file_exists" ]; then
        break
      fi
      echo "create context database returned with error [$e], retrying..."
      sleep 5
    else
      break
    fi
  done
  echo 'Created Cloudant Auth and Context dbs.'
}

### CREATE AUTHENTICATION DATABASE DOCUMENT
createAuthDoc() {
  AUTH_DOC=$(node -e 'const params = process.env;
  const doc = {
    slack: {
      client_id: params.__TEST_SLACK_CLIENT_ID,
      client_secret: params.__TEST_SLACK_CLIENT_SECRET,
      verification_token: params.__TEST_SLACK_VERIFICATION_TOKEN,
      access_token: params.__TEST_SLACK_ACCESS_TOKEN,
      bot_access_token: params.__TEST_SLACK_BOT_ACCESS_TOKEN
    },
    facebook: {
      app_secret: params.__TEST_FACEBOOK_APP_SECRET,
      verification_token: params.__TEST_FACEBOOK_VERIFICATION_TOKEN,
      page_access_token: params.__TEST_FACEBOOK_PAGE_ACCESS_TOKEN
    },
    conversation: {
      username: params.__TEST_CONVERSATION_USERNAME,
      password: params.__TEST_CONVERSATION_PASSWORD,
      workspace_id: params.__TEST_CONVERSATION_WORKSPACE_ID
    }
  };

  console.log(JSON.stringify(doc));
  ')
}

### Create all Whisk artifacts needed for running the test suite
createWhiskArtifacts() {
  echo 'Creating Whisk packages and actions...'

  # Generate the pipeline auth key
  PIPELINE_AUTH_KEY=`uuidgen`

  ## UPDATE ALL RELEVANT RESOURCES
  cd starter-code; ./setup.sh "${__TEST_PIPELINE_NAME}_"; cd ..
  cd conversation; ./setup.sh "${__TEST_PIPELINE_NAME}_"; cd ..
  cd context; ./setup.sh "${__TEST_PIPELINE_NAME}_"; cd ..

  cd channels;
  cd facebook; ./setup.sh "${__TEST_PIPELINE_NAME}_"; cd ..
  cd slack; ./setup.sh "${__TEST_PIPELINE_NAME}_"; cd ..;cd ..;

  ## CREATE CREDENTIALS DOCUMENT IN AUTH DATABASE
  createAuthDoc # creates the Auth doc JSON and stores it into $AUTH_DOC
  for i in {1..10}; do
    e=`curl -s -XPUT -d $AUTH_DOC ${CLOUDANT_URL}/${CLOUDANT_AUTH_DBNAME}/${PIPELINE_AUTH_KEY} | jq -er .error`
    if [ "$?" == "0" ]; then
      if [ "$e" == "conflict" -o "$e" == "file_exists" ]; then
        break
      fi
      echo "create auth database document returned with error [${e}], retrying..."
      sleep 5
    else
      break
    fi
  done

  echo "Your Cloudant Auth DB URL is: ${CLOUDANT_URL}/${CLOUDANT_AUTH_DBNAME}/${PIPELINE_AUTH_KEY}"

  ## INJECT ANNOTATIONS INTO ALL PACKAGES
  for line in `wsk package list | grep "/${__TEST_PIPELINE_NAME}_"`; do
    # this creates issues if the package name contains spaces
    resource=`echo $line | awk '{print $1}'`
    package=${resource##*/}

    ${WSK} package update $package \
      -a cloudant_auth_key "${PIPELINE_AUTH_KEY}" \
      -a cloudant_url "${CLOUDANT_URL}" \
      -a cloudant_auth_dbname "${CLOUDANT_AUTH_DBNAME}" \
      -a cloudant_context_dbname "${CLOUDANT_CONTEXT_DBNAME}" &> /dev/null
  done
}

setupTestArtifacts() {
  echo 'Running test setup scripts...'
  # Run setup scripts needed to build "mock" actions for integration tests
  SETUP_SCRIPT='./test/integration/conversation/setup.sh'
  if [ -f $SETUP_SCRIPT ]; then
    bash $SETUP_SCRIPT $__TEST_PIPELINE_NAME
  fi
  SETUP_SCRIPT='./test/integration/starter-code/setup.sh'
  if [ -f $SETUP_SCRIPT ]; then
    bash $SETUP_SCRIPT $__TEST_PIPELINE_NAME
  fi
  for folder in './test/integration/channels'/*; do
    if [ -d $folder ]; then
      SETUP_SCRIPT="$folder/setup.sh"
      if [ -f $SETUP_SCRIPT ]; then
        bash $SETUP_SCRIPT $__TEST_PIPELINE_NAME
      fi
    fi
  done
  SETUP_SCRIPT='./test/integration/context/setup.sh'
  if [ -f $SETUP_SCRIPT ]; then
    bash $SETUP_SCRIPT $__TEST_PIPELINE_NAME
  fi

  SETUP_SCRIPT='./test/end-to-end/setup.sh'
  if [ -f $SETUP_SCRIPT ]; then
    bash $SETUP_SCRIPT $__TEST_PIPELINE_NAME
  fi

  # Export the Openwhisk credentials for tests
  export __OW_API_KEY=`${WSK} property get --auth | tr "\t" "\n" | tail -n 1`
  export __OW_NAMESPACE=`${WSK} namespace list | tail -n +2 | head -n 1`
}

destroyTestArtifacts() {
  echo 'Running test breakdown scripts...'
  # Run breakdown scripts that deletes the "mock" actions for integration tests
  BREAKDOWN_SCRIPT='./test/integration/conversation/breakdown.sh'
  if [ -f $BREAKDOWN_SCRIPT ]; then
    bash $BREAKDOWN_SCRIPT $__TEST_PIPELINE_NAME
  fi
  BREAKDOWN_SCRIPT='./test/integration/starter-code/breakdown.sh'
  if [ -f $BREAKDOWN_SCRIPT ]; then
    bash $BREAKDOWN_SCRIPT $__TEST_PIPELINE_NAME
  fi
  for folder in './test/integration/channels'/*; do
    if [ -d $folder ]; then
      BREAKDOWN_SCRIPT="$folder/breakdown.sh"
      if [ -f $BREAKDOWN_SCRIPT ]; then
        bash $BREAKDOWN_SCRIPT $__TEST_PIPELINE_NAME
      fi
    fi
  done
  BREAKDOWN_SCRIPT='./test/integration/context/breakdown.sh'
  if [ -f $BREAKDOWN_SCRIPT ]; then
    bash $BREAKDOWN_SCRIPT $__TEST_PIPELINE_NAME
  fi
  BREAKDOWN_SCRIPT='./test/end-to-end/breakdown.sh'
  if [ -f $BREAKDOWN_SCRIPT ]; then
    bash $BREAKDOWN_SCRIPT $__TEST_PIPELINE_NAME
  fi
}

destroyWhiskArtifactsAndDatabases() {
  # Clean up wsk artifacts-packages and actions
  ./test/scripts/clean.sh ${__TEST_PIPELINE_NAME}

  # Delete the Cloudant dbs-contextdb and authdb once tests complete
  deleteCloudantDb ${CLOUDANT_URL} ${CLOUDANT_CONTEXT_DBNAME}
  deleteCloudantDb ${CLOUDANT_URL} ${CLOUDANT_AUTH_DBNAME}
}

runTestSuite() {
  # Run tests with coverage
  istanbul cover ./node_modules/mocha/bin/_mocha -- --recursive -R spec
  RETCODE=$?
}

# Deletes a cloudant database
# $1 - cloudant_url
# $2 - database_name
deleteCloudantDb(){
  echo "Deleting cloudant database $2"
  curl -s -XDELETE "$1/$2" | grep -v "error"
}

main

exit $RETCODE
