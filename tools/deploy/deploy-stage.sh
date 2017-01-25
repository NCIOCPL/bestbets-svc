#!/bin/sh
# Deploy to staging

export SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export RUN_SCRIPTS="../run"
export RUN_LOCATION="bestbets-run"

# Determine what configuration file to use.
configuration="${SCRIPT_PATH}/deploy-stage.config"

if [ ! -f $configuration ]; then
    echo "Configuration file '${configuration}' not found"
fi


#   Need to import:
#       - Version number to run
#       - SSH credentials

# Read configuration
export configData=`cat $configuration`
while IFS='=' read -r name value || [ -n "$name" ]
do
    if [ "$name" = "indexer_server" ];then export indexer_server="$value"; fi
    if [ "$name" = "server_list" ];then export server_list="$value"; fi
    if [ "$name" = "release_version" ];then export release_version="$value"; fi
    if [ "$name" = "api_instance_list" ];then export api_instance_list="$value"; fi
done <<< "$configData"

IFS=', ' read -r -a server_list <<< "$server_list"
IFS=', ' read -r -a api_instance_list <<< "$api_instance_list"

# Check for required config values
if [ -z "$indexer_server" ]; then echo "indexer_server not set, aborting."; exit 1; fi
if [ -z "$server_list" ]; then echo "server_list not set, aborting."; exit 1; fi
if [ -z "$release_version" ]; then echo "release_version not set, aborting."; exit 1; fi
if [ -z "$api_instance_list" ]; then echo "api_instance_list not set, aborting."; exit 1; fi

# Check for required environment variables
if [ -z "$DOCKER_USER" ]; then echo "DOCKER_USER not set, aborting."; exit 1; fi
if [ -z "$DOCKER_PASS" ]; then echo "DOCKER_PASS not set, aborting."; exit 1; fi


# Deploy support script collection.
for server in "${server_list[@]}"
do
    echo "Deploying run scripts to ${server}"
    ssh -q ${server} mkdir -p ${RUN_LOCATION}
    scp -q ${RUN_SCRIPTS}/* ${server}:${RUN_LOCATION}
done

##################################################################
#   Suspend Indexer
##################################################################
echo "Suspending indexers on ${indexer_server}"
ssh -q ${indexer_server} ${RUN_LOCATION}/stop-indexers.sh

##################################################################
#   Per server steps.
##################################################################
for server in "${server_list[@]}"
do


#        Deploy configuration (Write a persistent something or other telling the system which tag it's going to use)

    # Stop existing API container
    ssh -q ${server} ${RUN_LOCATION}/stop-api.sh

    # Pull image for new version (pull version-specific tag)
    imageName="nciwebcomm/bestbets-api:runtime-${release_version}"
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
    testdata=$(curl -f --silent --write-out 'RESULT_CODE:%{http_code}' -XGET http://localhost:5006/bestbets/en/treatment)
    statusCode=${testdata:${#testdata}-3}
    testdata=${testdata:${#testdata}-15}
    dataLength=${#testdata}

    # Check for statusCode other than 200 or short testdata.
    if [ "$statusCode" != "200" && dataLength > 100 ]; then
        # All is well,
        #   Remove old image
        #   Continue on next server.
    else
        # Error:
        #   Roll back to previous image
    fi

done

# Report that deployment has completed.

# Run indexer(?) (Command line switch?)


##################################################################
#   Allow scheduled indexing to resume
##################################################################
echo "Resuming indexers on ${indexer_server}"
ssh -q ${indexer_server} ${RUN_LOCATION}/resume-indexers.sh
