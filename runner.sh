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

command_exists() {
  if type "$1" &> /dev/null; then
    echo 1
  else
    echo 0
  fi
}

# somewhere timeout dose not exist
if [[ `command_exists timeout` -eq 0 ]]; then
  echo "Timeout function was not found and will be created!"
  timeout() {
    perl -e "alarm shift; exec @ARGV" "$@";
  }
fi

install_gcloud_sdk() {
  echo "Installing google SDK version ${GCLOUD_SDK_VERSION}"
  GCLOUD_SDK_FILENAME="google-cloud-sdk-${GCLOUD_SDK_VERSION}-linux-x86_64.tar.gz"
  GCLOUD_SDK_DOWNLOAD_PATH="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${GCLOUD_SDK_FILENAME}"
  # download google dsk
  curl -o ${GCLOUD_INSTALL_DIR}/google-cloud-sdk.tar.gz ${GCLOUD_SDK_DOWNLOAD_PATH}
  tar -xvf ${GCLOUD_INSTALL_DIR}/google-cloud-sdk.tar.gz -C ${GCLOUD_INSTALL_DIR}/
  # install google sdk
  ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/install.sh -q
  source ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/path.bash.inc
  gcloud components install kubectl -q
  gcloud components install docker-credential-gcr -q
  # apply google sdk config
  echo ${GCLOUD_API_KEYFILE} | base64 --decode --ignore-garbage > ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/gcloud-api-key.json
  gcloud auth activate-service-account --key-file ${GCLOUD_INSTALL_DIR}/google-cloud-sdk/gcloud-api-key.json
  gcloud config set project ${GCLOUD_PROJECT}
}

build_and_push_docker_container() {
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
  gcloud container clusters get-credentials $1 --zone ${GCLOUD_ZONE} --project ${GCLOUD_PROJECT}
  kubectl_apply_if_file deployment.yaml
  kubectl_apply_if_file service.yaml
}

testas() {
  sleep 5
  echo "yess"
}
