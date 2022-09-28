#!/bin/bash

# namespace. Warning it is hardcoded into acs/central.yaml and so

# ACS
PROJECT=acs
declare -r ADMPASSWD=redhat
BUNDLE_NAME=rhpds

oc new-project ${PROJECT}
oc delete limitrange -n ${PROJECT} ${PROJECT}-core-resource-limits

oc create -f acs/central.yaml
oc replace -f acs/central-secret.yaml

declare -r CENTRAL_HOST=$(oc get route central -n acs -o jsonpath='{.spec.host}')
CENTRAL_BUNDLES_URL="https://$CENTRAL_HOST/v1/cluster-init/init-bundles"

curl -X POST -k -u "admin:$ADMPASSWD" --header "Content-Type: application/json" --data '{"name":"'$BUNDLE_NAME'"}' $CENTRAL_BUNDLES_URL | jq -r '.kubectlBundle' | base64 -d | oc create -n $PROJECT  -f -

# curl -H "Authorization: Bearer $ROX_API_TOKEN" -X POST --data @security_permissions_set.json  --insecure $URL_CENTRAL

oc create -f acs/secured-cluster.yaml

## api
apicall() {
  curl -X POST -k -u "admin:$ADMPASSWD" --header "Content-Type: application/json" \
--data \
"${1}" \
https://${CENTRAL_HOST}/v1/"${2}"
}

## create roles and permission sets
apicall \
'
{
  "name": "Developers",
  "description": "Developers",
  "permissionSetId": "io.stackrox.authz.permissionset.none",
  "accessScopeId": "io.stackrox.authz.accessscope.unrestricted",
  "globalAccess": "NO_ACCESS"
}
' \
"roles/Developers"

apicall \
'
{
  "name": "Developers",
  "description": "For developers",
  "resourceToAccess": {
    "Detection": "READ_ACCESS",
    "Image": "READ_WRITE_ACCESS"
  }
}
' \
"permissionsets"

## create the auth provider

PROVIDER_ID=$(apicall \
'
{
  "id":"",
  "name":"rhpds",
  "type":"openshift",
  "config":{},
  "uiEndpoint":"'${CENTRAL_HOST}'",
  "enabled":true,
  "traits":{
    "mutabilityMode":"ALLOW_MUTATE"
  }
}
' \
"authProviders" \
| jq -r '.id')

## groupsbatch
apicall \
'
{
  "previous_groups":[],
  "required_groups":
  [{
    "roleName":"Developers",
    "props":{
      "authProviderId":"'${PROVIDER_ID}'",
      "key":"name",
      "value":"developer",
      "id":""}
  },
  {
    "props":{
      "authProviderId":"'${PROVIDER_ID}'"},
      "roleName":"None"
    }
  ]}
' \
"groupsbatch"

# Auth

#oc create secret generic htpass-secret --from-file=htpasswd=auth/users.htpasswd -n openshift-config
#oc create -f auth/oauth.yaml

oc get secret htpasswd-secret -ojsonpath={.data.htpasswd} -n openshift-config | base64 --decode > users.htpasswd
cat auth/users.htpasswd >> users.htpasswd
oc create secret generic htpasswd-secret --from-file=htpasswd=users.htpasswd --dry-run=client -o yaml -n openshift-config | oc replace -f -
rm users.htpasswd
