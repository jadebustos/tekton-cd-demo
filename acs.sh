#!/bin/bash

# namespace. Warning it is hardcoded into acs/central.yaml and so
# TODO ansible

set -e -u -o pipefail
#set -x

# ACS
PROJECT=acs
declare -r ADMPASSWD=redhat
BUNDLE_NAME=rhpds

oc new-project ${PROJECT}
oc delete limitrange -n ${PROJECT} ${PROJECT}-core-resource-limits

oc create -f acs/central-secret.yaml -n ${PROJECT}
oc create -f acs/central.yaml -n ${PROJECT}
printf "waiting...\n"
sleep 30
oc rollout status deployment central -n ${PROJECT} --timeout=5m

declare -r CENTRAL_HOST=$(oc get route central -n acs -o jsonpath='{.spec.host}')

#while [[ "$(curl -s -o /dev/null -k -u "admin:$ADMPASSWD" -w ''%{http_code}'' https://$CENTRAL_HOST/v1/ping)" != "200" ]]; do printf "waiting for ACS central endpoint availability"; sleep 5; done

CENTRAL_BUNDLES_URL="https://$CENTRAL_HOST/v1/cluster-init/init-bundles"

curl -X POST -k -u "admin:$ADMPASSWD" --header "Content-Type: application/json" --data '{"name":"'$BUNDLE_NAME'"}' $CENTRAL_BUNDLES_URL | jq -r '.kubectlBundle' | base64 -d | oc create -n $PROJECT  -f -

oc create -f acs/secured-cluster.yaml -n ${PROJECT}

# curl -H "Authorization: Bearer $ROX_API_TOKEN" -X POST --data @security_permissions_set.json  --insecure $URL_CENTRAL

apicall() {
  curl -X POST -k -u "admin:$ADMPASSWD" --header "Content-Type: application/json" \
--data \
"${1}" \
https://${CENTRAL_HOST}/v1/"${2}"
}

SUBJECTS=("developer" "security")

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

for subject in ${SUBJECTS[*]}; do

    ID=$(apicall \
      "@acs/${subject}-permission-sets.json" \
      "permissionsets" \
      | jq -r '.id')

    PAYLOAD=$(cat acs/role-${subject}.json \
      | jq '.permissionSetId = "'${ID}'"')

    apicall \
      "${PAYLOAD}" \
      "roles/${subject^}"

    apicall \
      '
      {
        "previous_groups":[],
        "required_groups":
      [{
        "roleName":"'${subject^}'",
        "props":{
        "authProviderId":"'${PROVIDER_ID}'",
        "key":"name",
        "value":"'${subject}'",
        "id":""}
      }
      ]}
      ' \
      "groupsbatch"
done

apicall \
  "@acs/log4j-policy.json" \
  "policies?enableStrictValidation=true"

#oc create secret generic htpass-secret --from-file=htpasswd=auth/users.htpasswd -n openshift-config
#oc create -f auth/oauth.yaml

oc get secret htpasswd-secret -ojsonpath={.data.htpasswd} -n openshift-config | base64 --decode > users.htpasswd
cat auth/users.htpasswd >> users.htpasswd
oc create secret generic htpasswd-secret --from-file=htpasswd=users.htpasswd --dry-run=client -o yaml -n openshift-config | oc replace -f -
rm users.htpasswd
