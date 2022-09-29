#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="demo"

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    -p|--project-prefix)
      PRJ_PREFIX=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*|--*)
      err "Error: Unsupported flag $1"
      ;;
    *) 
      break
  esac
done

declare -r dev_prj="$PRJ_PREFIX-dev"
declare -r stage_prj="$PRJ_PREFIX-stage"
declare -r cicd_prj="$PRJ_PREFIX-cicd"

GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)

sed "s/demo-dev/$dev_prj/g" pipelines/pipeline-deploy-dev-dummy.yaml | sed -E "s#https://github.com/siamaksade#http://$GOGS_HOSTNAME/gogs#g" | sed -E "s/spring/quarkus/g"| sed "s#quay.io/siamaksade#image-registry.openshift-image-registry.svc:5000#" | oc apply -f - -n $cicd_prj
