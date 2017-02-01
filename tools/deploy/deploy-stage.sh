#!/bin/sh
# Deploy to staging

########################################################################################
# 
# Required environment variables
# 
#   $INDEXER_SERVER - Contains the name of the server where the indexers run.
#   $SERVER_LIST - comma separated list of servers to deploy to
#   $RELEASE_VERSION - Version number to deploy (e.g 0.1.23)
# 
#   Credentials for pulling the container image from the central repository.
#   (NOTE: This is an NCI internal repository, not Docker Hub)
#   $DOCKER_USER - Userid for 
#   $DOCKER_PASS - Password for pulling the container image from the central repository.
# 
#   Elastic Search credentials. Assumed to be the same for both live and preview.
#   $ELASTICSEARCH_SERVERS - Comma separated list of ES servers.
#   $ELASTICSEARCH_INDEX_USER - User with ability to create new indnces
#   $ELASTICSEARCH_INDEX_PASSWORD - Password for index user.
#   $ELASTICSEARCH_SEARCH_USER - User with read-only access
#   $ELASTICSEARCH_SEARCH_PASSWORD - Password for search user.
#   $ELASTICSEARCH_LIVE_ALIAS - ES Alias to use for the live API/Index
#   $ELASTICSEARCH_PREVIEW_ALIAS - ES Alias to use for the preview API/Index
# 
#   Host for retrieving Best Bets data.
#   BESTBETS_HOST_LIVE
#   BESTBETS_HOST_PREVIEW
# 
########################################################################################


export SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export RUN_SCRIPTS="../run"
export RUN_LOCATION="bestbets-run"
export OLD_RUN_LOCATION="${RUN_LOCATION}-"`date +%Y%m%d-%H%M`


# Check for required environment variables
if [ -z "$INDEXER_SERVER" ]; then echo "INDEXER_SERVER not set, aborting."; exit 1; fi
if [ -z "$SERVER_LIST" ]; then echo "SERVER_LIST not set, aborting."; exit 1; fi
if [ -z "$RELEASE_VERSION" ]; then echo "RELEASE_VERSION not set, aborting."; exit 1; fi
if [ -z "$DOCKER_USER" ]; then echo "DOCKER_USER not set, aborting."; exit 1; fi
if [ -z "$DOCKER_PASS" ]; then echo "DOCKER_PASS not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_SERVERS" ]; then echo "ELASTICSEARCH_SERVERS not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_INDEX_USER" ]; then echo "ELASTICSEARCH_INDEX_USER not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_INDEX_PASSWORD" ]; then echo "ELASTICSEARCH_INDEX_PASSWORD not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_SEARCH_USER" ]; then echo "ELASTICSEARCH_SEARCH_USER not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_SEARCH_PASSWORD" ]; then echo "ELASTICSEARCH_SEARCH_PASSWORD not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_LIVE_ALIAS" ]; then echo "ELASTICSEARCH_LIVE_ALIAS not set, aborting."; exit 1; fi
if [ -z "$ELASTICSEARCH_PREVIEW_ALIAS" ]; then echo "ELASTICSEARCH_PREVIEW_ALIAS not set, aborting."; exit 1; fi
if [ -z "$BESTBETS_HOST_LIVE" ]; then echo "BESTBETS_HOST_LIVE not set, aborting."; exit 1; fi
if [ -z "$BESTBETS_HOST_PREVIEW" ]; then echo "BESTBETS_HOST_PREVIEW not set, aborting."; exit 1; fi


IFS=', ' read -r -a server_list <<< "$SERVER_LIST"

api_instance_list=("live" "preview")


# Deploy support script collection.
for server in "${server_list[@]}"
do
    echo "Copying run scripts to ${server}"
    ssh -q ${server} "[ -e ${RUN_LOCATION} ] && mv ${RUN_LOCATION} ${OLD_RUN_LOCATION}" # Backup existing files.
    ssh -q ${server} mkdir -p ${RUN_LOCATION}
    scp -q ${RUN_SCRIPTS}/* ${server}:${RUN_LOCATION}
done

##################################################################
#   Suspend Indexer
##################################################################
echo "Suspending indexers on ${INDEXER_SERVER}"
ssh -q ${INDEXER_SERVER} ${RUN_LOCATION}/stop-indexers.sh


##################################################################
#   Per server steps.
##################################################################
for server in "${server_list[@]}"
do


#        Deploy configuration (Write a persistent something or other telling the system which tag it's going to use)

    # Find out what images are already deployed for eventual cleanup.
    oldImageList=$(ssh -q $server ${RUN_LOCATION}/get-image-tag.sh nciwebcomm/bestbets-api)

    # Stop existing API container
    ssh -q ${server} ${RUN_LOCATION}/stop-api.sh

    # Pull image for new version (pull version-specific tag)
    imageName="nciwebcomm/bestbets-api:runtime-${RELEASE_VERSION}"
    ssh -q ${server} ${RUN_LOCATION}/pull-image.sh $imageName $DOCKER_USER $DOCKER_PASS

    # When we run the image, possibly run the indexer first.
    #   tools/run/bestbets-indexer.sh bestbets.indexer.config.live (or .preview)
    # This is something we'd want when changing the schema, probably involves introducing a new alias at the same time (said new alias would have no data until the indexer runs)

    # Start API via tools/run/bestbets-api.sh bestbets.api.config.live (or .preview)
    for instance in "${api_instance_list[@]}"
    do
        echo "Starting $instance API instance"
        ssh -q ${server} ${RUN_LOCATION}/bestbets-api.sh ${RUN_LOCATION}/bestbets-api-config.${instance}
    done

    # Test API availability by retrieving a Best Bet with at least one result.
    sleep 10 # Wait for the API to finish spinning up before querying.
    testdata=$(curl -f --silent --write-out 'RESULT_CODE:%{http_code}' -XGET http://${server}:5006/bestbets/en/treatment)

    statusCode=${testdata:${#testdata}-3}  # Get HTTP Status from end of output.
    testdata=${testdata:0:${#testdata}-15} # Trim the HTTP Status from output
    dataLength=${#testdata}

    # Check for statusCode other than 200 or short testdata.
    if [ "$statusCode" = "200" -a $dataLength -gt 100 -a "${testdata:0:1}" = "[" ]; then
        echo "Successfully deployed to ${server}"
        # All is well,
        #   Remove old image
        #   Continue on next server.
    else
        echo "Failed deploying to ${server}"
        [ "$statusCode" != 200 ] && echo "HTTP status: ${statusCode}"
        [ $dataLength -lt 101 ] && echo "Short data length (${dataLength})"
        [ "${testdata:0:1}" = "[" ] && echo "Incorrect starting character, expected '[', got '${testdata:0:1}'."
        echo "TestData '${testdata}'"
        # Error:
        #   Roll back to previous image
        exit 1
    fi

done


# Run indexer(?) (Command line switch?)


##################################################################
#   Allow scheduled indexing to resume
##################################################################
echo "Resuming indexers on ${INDEXER_SERVER}"
declare -A es_alias
es_alias["live"]=$ELASTICSEARCH_LIVE_ALIAS
es_alias["preview"]=$ELASTICSEARCH_PREVIEW_ALIAS
declare -A bb_host
bb_host['live']=$BESTBETS_HOST_LIVE
bb_host['preview']=$BESTBETS_HOST_PREVIEW
for instance in "${api_instance_list[@]}"
do
    echo "FF: ${es_alias[$instance]}"
    echo "F2: ${instance}"
    indexerCommand="docker run --name bestbets-indexer-${instance}  \
        --rm \
        -e CDEPubContentListingService__Host=\"${bb_host[$instance]}\" \
        -e CGBestBetsDisplayService__Host=\"${bb_host[$instance]}\"  \
        -e Elasticsearch__Servers=\"${ELASTICSEARCH_SERVERS}\" \
        -e Elasticsearch__Userid=\"${ELASTICSEARCH_INDEX_USER}\" \
        -e Elasticsearch__Password=\"${ELASTICSEARCH_INDEX_PASSWORD}\" \
        -e ESBBIndexerService__AliasName=\"${es_alias[$instance]}\" \
        --entrypoint dotnet \
        nciwebcomm/bestbets-api:runtime-${RELEASE_VERSION} \
        /home/containeruser/indexer/NCI.OCPL.Api.BestBets.Indexer.dll"
    echo =============================================================
    echo $indexerCommand
    echo =============================================================
    #ssh -q ${INDEXER_SERVER} ${RUN_LOCATION}/resume-indexers.sh
done