#!/bin/bash

assert_success() {
  if [[ "${status:-}" != 0 ]]; then
    echo "expected: 0"
    echo "actual: ${status:-}"
    echo "output: ${output:-}"
    return 1
  fi
}

assert_failure() {
  if [[ "${status:-}" == 0 ]]; then
    echo "expected: non-zero exit code"
    echo "actual: ${status:-}"
    echo "output: ${output:-}"
    return 1
  fi
}

archive_provider() {
    # Determine log directory
  if [[ -z "${ARTIFACTS}" ]]; then
    return 0
  fi

  FILE_PREFIX=$(date +"%FT%H%M%S")

  kubectl logs -l "$1" --tail -1 -n secrets-store-sync-controller-system > "${ARTIFACTS}/${FILE_PREFIX}-provider.logs"
}

archive_info() {
  # Determine log directory
  if [[ -z "${ARTIFACTS}" ]]; then
    return 0
  fi

  LOGS_DIR="${ARTIFACTS}/$(date +"%FT%H%M%S")"
  mkdir -p "${LOGS_DIR}"

  # print all pod information
  kubectl get pods -A -o json > "${LOGS_DIR}/pods.json"

  # print detailed pod information
  kubectl describe pods --all-namespaces > "${LOGS_DIR}/pods-describe.txt"

  # print logs from the secrets-store-sync-controller
  #
  # assumes secrets-store-sync-controller is installed with helm into the `secrets-store-sync-controller-system` namespace which
  # sets the `app` selector to `secrets-store-sync-controller`.
  #
  # Note: the yaml deployment would require `app=secrets-store-sync-controller`
  kubectl logs -l app=secrets-store-sync-controller --tail -1 -c manager -n secrets-store-sync-controller-system > "${LOGS_DIR}/secrets-store-sync-controller.log"
  kubectl logs -l app=secrets-store-sync-controller   --tail -1 -c provider-e2e-installer -n secrets-store-sync-controller-system > "${LOGS_DIR}/e2e-provider.log"

  # print client and server version information
  kubectl version > "${LOGS_DIR}/kubectl-version.txt"

  # print generic cluster information
  kubectl cluster-info dump > "${LOGS_DIR}/cluster-info.txt"

  # collect metrics
  local curl_pod_name
  curl_pod_name="curl-$(openssl rand -hex 5)"
  kubectl run "${curl_pod_name}" -n default --image=curlimages/curl:7.75.0 --labels="test=metrics_test" --overrides='{"spec": { "nodeSelector": {"kubernetes.io/os": "linux"}}}' -- tail -f /dev/null
  kubectl wait --for=condition=Ready --timeout=60s -n default pod "${curl_pod_name}"

  for pod_ip in $(kubectl get pod -n secrets-store-sync-controller-system -l app=secrets-store-sync-controller  -o jsonpath="{.items[*].status.podIP}")
  do
    kubectl exec -n default "${curl_pod_name}" -- curl -s http://"${pod_ip}":8085/metrics > "${LOGS_DIR}/${pod_ip}.metrics"
  done

  kubectl delete pod -n default "${curl_pod_name}"
}

compare_owner_count() {
  secret="$1"
  namespace="$2"
  ownercount="$3"

  [[ "$(kubectl get secret "${secret}" -n "${namespace}" -o json | jq '.metadata.ownerReferences | length')" -eq $ownercount ]]
}

create_namespace() {
  local namespace="$1"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
}

deploy_and_wait_for_resource() {
  local namespace="$1"
  local yaml_file="$2"
  local resource_name="$3"
  local resource_type="$4"
  local wait_time="${5:-$WAIT_TIME}"
  local sleep_time="${6:-$SLEEP_TIME}"

  kubectl apply -n "$namespace" -f "$yaml_file"
  wait_for_process "$wait_time" "$sleep_time" "kubectl get ${resource_type}/${resource_name} -n ${namespace} -o yaml | grep ${resource_name}"
}

verify_secretsync_status() {
  local name="$1"
  local namespace="$2"
  local expected_message="$3"
  local expected_reason="$4"
  local expected_status="$5"
  local timeout=60
  local interval=5
  local elapsed=0

  while (( elapsed < timeout )); do
    # Attempt to fetch the status
    local status
    status=$(kubectl get secretsyncs.secret-sync.x-k8s.io/"$name" -n "${namespace}" -o jsonpath='{.status.conditions[0]}' 2>/dev/null || echo "")

    # If the status is not empty, perform verification
    if [[ -n "$status" ]]; then
      local message
      message=$(echo "$status" | jq -r .message)
      
      local reason
      reason=$(echo "$status" | jq -r .reason)
      
      local status_value
      status_value=$(echo "$status" | jq -r .status)

      if [[ "${message}" == "${expected_message}" && "${reason}" == "${expected_reason}" && "${status_value}" == "${expected_status}" ]]; then
        echo "Status verified successfully for SecretSync: ${name} in namespace: ${namespace}"
        return 0
      else
        echo "Status: ${status} found but does not match expected values for SecretSync: ${name} in namespace: ${namespace}"
        return 1
      fi
    fi

    # Sleep and increment elapsed time only if the status was empty
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "Timeout reached while waiting for SecretSync status to become available for: $name in namespace: $namespace"
  return 1
}


verify_secret_not_exists() {
  local name="$1"
  local namespace="$2"
  cmd="kubectl get secret ${name} -n ${namespace}"
  run $cmd
  assert_failure
}

deploy_spc_ss_verify_conditions() {
  local provider_yaml="$1"
  local sync_yaml="$2"
  local sync_name="$3"
  local expected_message="$4"
  local expected_reason="$5"
  local expected_status="$6"
  local spc_namespace="${7:-default}"
  local ss_namespace="${8:-default}"
  
  # Deploy SecretProviderClass and wait for it
  deploy_and_wait_for_resource "${spc_namespace}" "${provider_yaml}" "e2e-providerspc" "secretproviderclasses.secrets-store.csi.x-k8s.io"

  # Deploy SecretSync and wait for it
  deploy_and_wait_for_resource "${ss_namespace}" "${sync_yaml}" "${sync_name}" "secretsyncs.secret-sync.x-k8s.io"

  # Verify SecretSync status
  verify_secretsync_status "${sync_name}" "${ss_namespace}" "${expected_message}" "${expected_reason}" "${expected_status}"

  # Verify secret is not created
  verify_secret_not_exists "${sync_name}" "${ss_namespace}"
}

deploy_spc_ss_expect_failure() {
  local spc_yaml="$1"
  local ss_yaml="$2"
  local sync_name="$3"
  local expected_message="$4"
  local spc_namespace="${5:-default}"
  local ss_namespace="${6:-default}"

  # Deploy SecretProviderClass and wait for it
  deploy_and_wait_for_resource "${spc_namespace}" "${spc_yaml}" "e2e-providerspc" "secretproviderclasses.secrets-store.csi.x-k8s.io"

  # Deploy SecretSync and expect it to fail
  output=$(kubectl apply -n "${ss_namespace}" -f "${ss_yaml}" 2>&1 || true)
  [[ "${output}" == *"${expected_message}"* ]]

  # Verify secret is not created
  verify_secret_not_exists "${sync_name}" "${ss_namespace}"
}

wait_for_process() {
  wait_time="$1"
  sleep_time="$2"
  cmd="$3"
  while [ "$wait_time" -gt 0 ]; do
    if eval "$cmd"; then
      return 0
    else
      sleep "$sleep_time"
      wait_time=$((wait_time-sleep_time))
    fi
  done
  return 1
}
