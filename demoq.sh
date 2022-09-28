#!/bin/bash

set -e -u -o pipefail
declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PRJ_PREFIX="demo"
declare COMMAND="help"

valid_command() {
  local fn=$1; shift
  [[ $(type -t "$fn") == "function" ]]
}

info() {
    printf "\n# INFO: $@\n"
}

err() {
  printf "\n# ERROR: $1\n"
  exit 1
}

while (( "$#" )); do
  case "$1" in
    install|uninstall|start|promote|status)
      COMMAND=$1
      shift
      ;;
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

command.help() {
  cat <<-EOF

  Usage:
      demo [command] [options]
  
  Example:
      demo install --project-prefix mydemo
  
  COMMANDS:
      install                        Sets up the demo and creates namespaces
      uninstall                      Deletes the demo
      status
      start                          Starts the deploy DEV pipeline
      promote                        Starts the deploy STAGE pipeline
      help                           Help about this command

  OPTIONS:
      -p|--project-prefix [string]   Prefix to be added to demo project names e.g. PREFIX-dev
EOF
}

command.install() {
  oc version >/dev/null 2>&1 || err "no oc binary found"

  info "Creating namespaces $cicd_prj, $dev_prj, $stage_prj"
  oc get ns $cicd_prj 2>/dev/null  || { 
    oc new-project $cicd_prj
    oc delete limitrange -n $cicd_prj ${cicd_prj}-core-resource-limits || true
  }
  oc get ns $dev_prj 2>/dev/null  || { 
    oc new-project $dev_prj
    oc delete limitrange -n $dev_prj ${dev_prj}-core-resource-limits || true
  }
  oc get ns $stage_prj 2>/dev/null  || { 
    oc new-project $stage_prj 
    oc delete limitrange -n $stage_prj ${stage_prj}-core-resource-limits || true
  }

  info "Configure service account permissions for pipeline"
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $dev_prj
  oc policy add-role-to-user edit system:serviceaccount:$cicd_prj:pipeline -n $stage_prj
  oc policy add-role-to-user edit system:serviceaccount:$stage_prj:default -n $dev_prj

  info "Deploying CI/CD infra to $cicd_prj namespace"
  oc apply -f cd -n $cicd_prj
  GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)

  info "Deploying pipeline and tasks to $cicd_prj namespace"
  oc apply -f tasks -n $cicd_prj
  sed -E "s#quay.io/siamaksade/spring#image-registry.openshift-image-registry.svc:5000/quarkus#g" tasks/deploy-app-task.yaml | oc apply -f - -n $cicd_prj

  oc create -f config/maven-settings-configmap.yaml -n $cicd_prj
  oc apply -f config/pipeline-pvc.yaml -n $cicd_prj
  sed "s/demo-dev/$dev_prj/g" pipelines/pipeline-deploy-dev.yaml | sed -E "s#https://github.com/siamaksade#http://$GOGS_HOSTNAME/gogs#g" | sed -E "s/spring/quarkus/g"| sed "s#quay.io/siamaksade#image-registry.openshift-image-registry.svc:5000#" | oc apply -f - -n $cicd_prj

  sed "s/demo-dev/$dev_prj/g" pipelines/pipeline-deploy-stage.yaml | sed -E "s/demo-stage/$stage_prj/g" | sed -E "s#https://github.com/siamaksade#http://$GOGS_HOSTNAME/gogs#g" | sed -E "s/spring/quarkus/g" | oc apply -f - -n $cicd_prj

  oc apply -f triggers/gogs-triggerbinding.yaml -n $cicd_prj
  oc apply -f triggers/triggertemplate.yaml -n $cicd_prj
  sed "s/demo-dev/$dev_prj/g" triggers/eventlistener.yaml | oc apply -f - -n $cicd_prj

  info "Initiatlizing git repository in Gogs and configuring webhooks"
  sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" config/gogs-configmap.yaml | oc create -f - -n $cicd_prj
  oc rollout status deployment/gogs -n $cicd_prj

  # TODO replace log messages
  sed 's#"https://github.com/siamaksade/spring-petclinic"#"https://github.com/aolle/quarkus-petclinic"#' config/gogs-init-taskrun.yaml \
  | sed 's#spring-petclinic/hooks#quarkus-petclinic/hooks#' \
  | sed 's#spring-petclinic-config/hooks#quarkus-petclinic-config/hooks#' \
  | sed 's#\(.*data_repo.*quarkus-petclinic.*repo_name.*\)spring-petclinic\(.*\)#\1quarkus-petclinic\2#' \
  | sed 's#"https://github.com/siamaksade/spring-petclinic-config.git"#"https://github.com/aolle/quarkus-petclinic-config"#' \
  | sed 's/spring-petclinic-config/quarkus-petclinic-config/' \
  | sed 's#\(.*data_repo.*spring-petclinic-gatling.*repo_name.*\)spring-petclinic-gatling\(.*\)#\1quarkus-petclinic-gatling\2#' \
  | sed '/petclinic-config.hooks/,+9 s/^/          #/' \
  | oc create -f - -n $cicd_prj

  oc adm policy add-role-to-user edit developer -n demo-cicd
  oc adm policy add-role-to-user edit developer -n demo-dev
  
  cat <<-EOF

############################################################################
############################################################################

  Demo is installed! Give it a few minutes to finish deployments and then:

  1) Go to spring-petclinic Git repository in Gogs:
     http://$GOGS_HOSTNAME/gogs/spring-petclinic.git
  
  2) Log into Gogs with username/password: gogs/gogs
      
  3) Edit a file in the repository and commit to trigger the pipeline

  4) Check the pipeline run logs in Dev Console or Tekton CLI:
     
    \$ tkn pipeline logs petclinic-deploy-dev -f -n $cicd_prj

  
  You can find further details at:
  
  Gogs Git Server: http://$GOGS_HOSTNAME/explore/repos
  Reports Server: http://$(oc get route reports-repo -o template --template='{{.spec.host}}' -n $cicd_prj)
  SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
  Sonatype Nexus: http://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)

############################################################################
############################################################################
EOF
}

command.start() {
  oc create -f runs/pipeline-deploy-dev-run.yaml -n $cicd_prj
}

command.promote() {
  oc create -f runs/pipeline-deploy-stage-run.yaml -n $cicd_prj
}

command.uninstall() {
  oc delete project $dev_prj $stage_prj $cicd_prj
}

command.status() {
cat <<-EOF
    Gogs Git Server: http://$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)/explore/repos
    Reports Server: http://$(oc get route reports-repo -o template --template='{{.spec.host}}' -n $cicd_prj)
    SonarQube: https://$(oc get route sonarqube -o template --template='{{.spec.host}}' -n $cicd_prj)
    Sonatype Nexus: http://$(oc get route nexus -o template --template='{{.spec.host}}' -n $cicd_prj)
EOF
}

main() {
  local fn="command.$COMMAND"
  valid_command "$fn" || {
    err "invalid command '$COMMAND'"
  }

  cd $SCRIPT_DIR
  $fn
  return $?
}

main
