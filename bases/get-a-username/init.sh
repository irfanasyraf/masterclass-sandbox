#!/bin/bash
set -euo pipefail

USER_PREFIX="user"
USER_COUNT=10

# Set this locally before running — do NOT push a real password back to git.
# This is the one value in this file you're expected to edit on your machine
# and never commit; everything ArgoCD deploys only ever sees placeholders.
WORKSHOP_PASSWORD="dry-run"

if [[ "${WORKSHOP_PASSWORD}" == "CHANGE_ME_BEFORE_RUNNING" ]]; then
    echo "ERROR: edit WORKSHOP_PASSWORD at the top of this script before running it." >&2
    exit 1
fi

HTPASSWD_SECRET_NAME="workshop-htpasswd"
HTPASSWD_SECRET_NAMESPACE="openshift-config"
HTPASSWD_IDP_NAME="workshop-htpasswd"
GET_A_USERNAME_SECRET_NAME="get-a-username-secret"
GET_A_USERNAME_CONFIG_NAME="get-a-username-config"
GET_A_USERNAME_SECRET_NAMESPACE="guides"

create_workshop_auth() {
    echo "Generating htpasswd file for ${USER_COUNT} users..."
    local htpasswd_file
    htpasswd_file="$(mktemp)"
    trap 'rm -f "${htpasswd_file}"' RETURN

    for i in $(seq 1 "${USER_COUNT}"); do
        htpasswd -Bbn "${USER_PREFIX}${i}" "${WORKSHOP_PASSWORD}" >> "${htpasswd_file}"
    done

    echo "Creating/updating Secret ${HTPASSWD_SECRET_NAME} in ${HTPASSWD_SECRET_NAMESPACE}..."
    oc create secret generic "${HTPASSWD_SECRET_NAME}" \
        -n "${HTPASSWD_SECRET_NAMESPACE}" \
        --from-file=htpasswd="${htpasswd_file}" \
        --dry-run=client -o yaml | oc apply -f -

    echo "Fetching current identity providers from cluster..."
    local current_oauth
    current_oauth="$(oc get oauth cluster -o json 2>/dev/null)"

    # Safety check: Ensure cluster returned valid JSON with a spec block
    if [ -z "${current_oauth}" ]; then
        echo "ERROR: Failed to fetch oauth/cluster resources. Aborting patch to protect existing auth." >&2
        return 1
    fi

    # Build the workshop provider JSON object
    local workshop_provider
    workshop_provider="$(jq -n \
        --arg name "${HTPASSWD_IDP_NAME}" \
        --arg secret "${HTPASSWD_SECRET_NAME}" \
        '{
            name: $name,
            mappingMethod: "claim",
            type: "HTPasswd",
            htpasswd: { fileData: { name: $secret } }
        }')"

    echo "Merging ${HTPASSWD_IDP_NAME} into oauth/cluster identity providers..."
    local merged_providers
    merged_providers="$(echo "${current_oauth}" | jq --argjson new_provider "${workshop_provider}" '
        (.spec.identityProviders // [])
        | map(select(.name != $new_provider.name))
        + [$new_provider]
    ')"

    # Apply the merged provider list
    oc patch oauth cluster --type=merge -p "$(jq -n --argjson providers "${merged_providers}" '{spec: {identityProviders: $providers}}')"

    if ! oc get secret "${GET_A_USERNAME_SECRET_NAME}" -n "${GET_A_USERNAME_SECRET_NAMESPACE}" &>/dev/null; then
        echo "ERROR: ${GET_A_USERNAME_SECRET_NAME} not found in ${GET_A_USERNAME_SECRET_NAMESPACE}." >&2
        echo "Make sure ArgoCD has synced the get-a-username Application first, then re-run this script." >&2
        exit 1
    fi

    echo "Setting ${GET_A_USERNAME_SECRET_NAME} in ${GET_A_USERNAME_SECRET_NAMESPACE} to the same password..."
    oc patch secret "${GET_A_USERNAME_SECRET_NAME}" -n "${GET_A_USERNAME_SECRET_NAMESPACE}" \
        --type=merge -p "$(jq -n --arg pass "${WORKSHOP_PASSWORD}" '{
            stringData: {
                LAB_USER_ACCESS_TOKEN: $pass,
                LAB_USER_PASS: $pass,
                LAB_ADMIN_PASS: $pass
            }
        }')"

    echo "Done. The authentication operator will briefly roll (~30-60s):"
    echo "  oc get co authentication -w"
}

# Points the get-a-username "Modules" panel at the real console/DevSpaces
# routes on this cluster instead of the placeholder domain committed in
# configmap.yaml, so you never have to hand-edit it per cluster.
sync_get_a_username_urls() {
    echo "Looking up cluster routes for the get-a-username Modules panel..."

    local console_url
    console_url="$(oc whoami --show-console)"

    local devspaces_host
    devspaces_host="$(oc get routes -A -o json \
        | jq -r '[.items[] | select(.metadata.name | test("devspaces|^che$"; "i"))][0].spec.host // empty')"

    local module_urls="${console_url};OpenShift Console"
    if [[ -n "${devspaces_host}" ]]; then
        module_urls="${module_urls},https://${devspaces_host};OpenShift Dev Spaces Console"
    else
        echo "NOTE: no devspaces/che route found on this cluster — omitting Dev Spaces Console link."
    fi

    oc patch configmap "${GET_A_USERNAME_CONFIG_NAME}" -n "${GET_A_USERNAME_SECRET_NAMESPACE}" \
        --type=merge -p "$(jq -n --arg modules "${module_urls}" '{
            data: {
                LAB_MODULE_URLS: $modules,
                LAB_EXTRA_URLS: ""
            }
        }')"
}

echo "Generating ${USER_COUNT} namespace..."


for i in $(seq 1 ${USER_COUNT}); do
    USER_NAME="${USER_PREFIX}${i}"
    USER_NAMESPACE="${USER_PREFIX}${i}"
    # USER_NAMESPACE_SIT="${USER_PREFIX}${i}-sit"

    # apply instead of create — reruns safely if the namespace/user already exists
    oc create ns "${USER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
    oc label ns "${USER_NAMESPACE}" --overwrite \
        "app.kubernetes.io/part-of=che.eclipse.org" \
        "app.kubernetes.io/component=workspaces-namespace" \
        "openshift.io/cluster-monitoring=true"
    oc annotate ns "${USER_NAMESPACE}" --overwrite "che.eclipse.org/username=${USER_NAME}"
    oc create user "${USER_NAME}" --dry-run=client -o yaml | oc apply -f -
    oc adm policy add-role-to-user admin "${USER_NAME}" -n "${USER_NAMESPACE}"

    # USER_NAMESPACE_SIT="${USER_PREFIX}${i}-sit"
    # oc create ns ${USER_NAMESPACE_SIT}
    # oc adm policy add-role-to-user admin ${USER_NAME} -n ${USER_NAMESPACE_SIT}
    # oc label ns ${USER_NAMESPACE_SIT} "openshift.io/cluster-monitoring=true"

    echo "Done. namespace created for ${USER_NAME}."
done

create_workshop_auth
sync_get_a_username_urls

# ConfigMap/Secret env vars are only injected at container start — the running
# pod won't pick up either change above until it restarts.
echo "Restarting get-a-username so it picks up the new password and URLs..."
oc rollout restart deployment/get-a-username -n "${GET_A_USERNAME_SECRET_NAMESPACE}"
oc rollout status deployment/get-a-username -n "${GET_A_USERNAME_SECRET_NAMESPACE}" --timeout=60s