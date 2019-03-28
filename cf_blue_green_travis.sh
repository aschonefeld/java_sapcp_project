#!/bin/bash

#
# Define Functions
#

# Remove manifest information stored in the temporary directory
function finally ()
{
  echo "Delete Manifest"
  rm $MANIFEST
}

# Inform that the deployment has failed for some reason
function on_fail () {
  finally
  echo "DEPLOY FAILED - you may need to check 'cf apps' and 'cf routes' and do manual cleanup"

  # Set the Exit code to 1 to denote this as an erroneous Travis build
  exit 1
}

#
# Fist part: installation of the Cloud Foundry client
#

# Exit immediately in case of non-zero status return
Set -e

# Get the cloud foundry public key and add the repository
wget -q -O - https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | sudo apt-key add -
echo "deb http://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list

# Update the local package index, then install the cf CLI
sudo apt-get update
sudo apt-get install cf-cli

# Login to Cloud Foundry
cf api $CF_API #Use the cf api command to set the api endpoint
cf login -u $CF_USERNAME -p $CF_PASSWORD -o $CF_PROD_ORGANIZATION -s $CF_PROD_SPACE

# Get the script path to execute the script
pushd `dirname $0` > /dev/null
popd > /dev/null

#
# Second Part: blue-green deployment
#

#Store the current path
CURRENTPATH=$(pwd)

# Set the application name in BLUE variable
BLUE=$CF_APP

# Green variable will store a temporary name for the application
GREEN="${BLUE}-B"

# Pull the up-to-date manifest from the BLUE (existing) application
MANIFEST=$(mktemp -t "${BLUE}_manifestXXXXXXX.temp")

# Create the new manifest file for deployment
cf create-app-manifest $BLUE -p $MANIFEST

# Check in case of first run and empty manifest file
if [ ! -s $MANIFEST ]
then
  echo "applications:
- name: $BLUE
  instances: 1
  memory: 640M
  disk_quota: 512M
  routes:
  - route: $BLUE.$CF_DOMAIN" > $MANIFEST
  cf push -f $MANIFEST -p /tmp/$CF_APP.war
fi

# Find and replace the application name (to the name stored in green variable) in the manifest file
sed -i -e "s/: ${BLUE}/: ${GREEN}/g" $MANIFEST
sed -i -e "s?path: ?path: $CURRENTPATH/?g" $MANIFEST

trap on_fail ERR

# Prepare the URL of the green application
DOMAIN=$CF_DOMAIN
cf push -f $MANIFEST -p /tmp/$CF_APP.war
GREENURL=https://${GREEN}.${DOMAIN}

# Check the URL to find if it fails
curl --fail -I -k $GREENURL

# Reroute the application URL to the green process
cf routes | tail -n +4 | grep $BLUE | awk '{print $3" -n "$2}' | xargs -n 3 cf map-route $GREEN

# Perform deletion of old application and rename the green process to blue
cf delete $BLUE -f
cf rename $GREEN $BLUE
cf delete-route $DOMAIN -n $GREEN -f

# Clean up
finally

echo "DONE"
