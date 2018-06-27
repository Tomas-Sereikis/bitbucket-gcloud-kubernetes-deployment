#!/usr/bin/env bash

# global variables required to bet set in bitbucket env
# - BITBUCKET_CLONE_DIR is a bitbucket default variable - it is where git clone was made
# - BITBUCKET_BUILD_NUMBER is a bitbucket default variable for incremental build id
# - GCLOUD_API_KEYFILE is a base64 encoded google service account json key
# - GCLOUD_PROJECT is gcloud project name
# - GCLOUD_REPOSITORY is a name of repo where container will be stored
# - GCLOUD_ZONE zone where cluster is

GCLOUD_SDK_VERSION="203.0.0"
GCLOUD_INSTALL_DIR=${BITBUCKET_CLONE_DIR}

install_gcloud_sdk() {
  set -e
  echo "Installing google SDK version ${GCLOUD_SDK_VERSION}"
  GCLOUD_SDK_FILENAME="google-cloud-sdk-${GCLOUD_SDK_VERSION}-linux-x86_64.tar.gz"
  GCLOUD_SDK_DOWNLOAD_PATH="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${GCLOUD_SDK_FILENAME}"
  # download google dsk
  curl -o ${GCLOUD_INSTALL_DIR}/google-cloud-sdk.tar.gz ${GCLOUD_SDK_DOWNLOAD_PATH}
  tar -xvf ${GCLOUD_INSTALL_DIR}/google-cloud-sdk.tar.gz -C ${GCLOUD_INSTALL_DIR}/ 2>&1 > /dev/null
  # install google sdk
  ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/install.sh -q 2>&1 > /dev/null
  source ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/path.bash.inc
  gcloud components install kubectl -q
  gcloud components install docker-credential-gcr -q
  # apply google sdk config
  echo ${GCLOUD_API_KEYFILE} | base64 --decode --ignore-garbage > ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/gcloud-api-key.json
  gcloud auth activate-service-account --key-file ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/gcloud-api-key.json
  gcloud config set project ${GCLOUD_PROJECT}
}

include_gcloud_sdk() {
  source ${BITBUCKET_CLONE_DIR}/google-cloud-sdk/path.bash.inc
  gcloud auth activate-service-account --key-file ${BITBUCKET_CLONE_DIR}/google-cloud-sdk/gcloud-api-key.json
  gcloud config set project ${GCLOUD_PROJECT}
}

build_and_push_docker_container() {
  set -e
  include_gcloud_sdk
  docker-credential-gcr configure-docker
  docker build -t gcr.io/${GCLOUD_PROJECT}/${GCLOUD_REPOSITORY}:${BITBUCKET_BUILD_NUMBER} .
  docker push gcr.io/${GCLOUD_PROJECT}/${GCLOUD_REPOSITORY}:${BITBUCKET_BUILD_NUMBER}
}

kubectl_apply_if_file() {
  if [ -e $1 ]; then
    # try to replace some global stuff in file
    sed -i -e "s/{{image}}/gcr.io\/$GCLOUD_PROJECT\/$GCLOUD_REPOSITORY:$BITBUCKET_BUILD_NUMBER/g" $1
    kubectl apply -f $1
  else
    echo "kubectl file $1 was skipped because is it not found"
  fi
}

# this function takes one argument which is the cluster name
kubectl_deploy() {
  set -e
  KUBE_MIGRATION_NAME="$GCLOUD_REPOSITORY-migration"
  include_gcloud_sdk
  gcloud container clusters get-credentials $1 --zone ${GCLOUD_ZONE} --project ${GCLOUD_PROJECT}
  if [ -e migration.yaml ]; then
    MIGRATION_POD_STATUS_LINE=$(kubectl get pods | grep ${KUBE_MIGRATION_NAME} | cat)
    if [ ! -z "${MIGRATION_POD_STATUS_LINE}" ]; then
      echo "Deployment canceled due to that job pod ${KUBE_MIGRATION_NAME} already exists!"
      exit 1
    fi
    echo "Starting migration script..."
    kubectl_apply_if_file migration.yaml
    kubectl_run_migration ${KUBE_MIGRATION_NAME}
  fi
  echo "Starting deployment and service updates..."
  kubectl_apply_if_file deployment.yaml
  kubectl_apply_if_file service.yaml
}

kubectl_job_logs() {
  POD_STATUS_LINE=$(kubectl get pods | grep $1 | cat)
  POD_COUNT=$(echo ${POD_STATUS_LINE} | awk '{ print $2 }')
  POD_NAME=$(echo ${POD_STATUS_LINE} | awk '{ print $1 }')
  POD_STATUS=$(echo ${POD_STATUS_LINE} | awk '{ print $3 }')
  if [ "${POD_COUNT}" == "1/1" ]; then
    kubectl logs ${POD_NAME} --timestamps
  else
    kubectl logs ${POD_NAME} -c $1 --timestamps
  fi
}

kubectl_delete_migration() {
  KUBE_MIGRATION_NAME=$1
  JOB_STATUS_LINE=$(kubectl get pods | grep ${KUBE_MIGRATION_NAME} | cat)
  if [ -z "${JOB_STATUS_LINE}" ]; then
    echo "Can not delete job ${KUBE_MIGRATION_NAME} because it is not found"
  else
    kubectl delete job ${KUBE_MIGRATION_NAME}
  fi
}

kubectl_run_migration() {
  KUBE_MIGRATION_NAME=$1
  LOOP_TIMES=600
  for i in `seq 1 ${LOOP_TIMES}`; do
    sleep 0.5
    POD_STATUS_LINE=$(kubectl get pods | grep ${KUBE_MIGRATION_NAME} | cat)
    if [ -z "${POD_STATUS_LINE}" ]; then
      echo "Job pod ${KUBE_MIGRATION_NAME} was not found"
      exit 1
    else
      POD_NAME=$(echo ${POD_STATUS_LINE} | awk '{ print $1 }')
      POD_STATUS=$(echo ${POD_STATUS_LINE} | awk '{ print $3 }')
      if [ "${POD_STATUS}" == "Completed" ]; then
        kubectl_job_logs ${KUBE_MIGRATION_NAME}
        kubectl delete job ${KUBE_MIGRATION_NAME}
        break
      elif [ "${POD_STATUS}" == "Error" ]; then
        kubectl_job_logs ${KUBE_MIGRATION_NAME}
        kubectl delete job ${KUBE_MIGRATION_NAME}
        echo "Job finished with at error!"
        exit 1
      else
        echo "Job ${KUBE_MIGRATION_NAME} pod ${POD_NAME} is in ${POD_STATUS} status"
      fi
    fi
  done
  if [ ${i} -eq ${LOOP_TIMES} ]; then
    echo "Out of retries"
    exit 1
  fi
}
