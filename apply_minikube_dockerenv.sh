#!/usr/bin/env bash

# Deploy the application to a Minikube Docker-driver profile without changing manifests.
# Set MINIKUBE_PROFILE to target a profile other than "minikube".
set -Eeuo pipefail

# Install/check Git, then clone or reuse the deployment repository.
REPO_URL="https://github.com/Michaelo233/module5-part3-Michael.git"
REPO_NAME="module5-part3-Michael"
REPO_DIR="${DEPLOY_REPO_DIR:-$PWD/$REPO_NAME}"

if command -v git >/dev/null 2>&1; then
    printf 'Git is already installed.\n'
else
    if command -v apt-get >/dev/null 2>&1; then
        if [[ "$(id -u)" -eq 0 ]]; then
            apt-get update && apt-get install -y git
        elif command -v sudo >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y git
        else
            printf 'Git is missing and sudo is not available to install it.\n' >&2
            exit 1
        fi
    elif command -v brew >/dev/null 2>&1; then
        brew install git
    else
        printf 'Git is missing and no supported package manager (apt-get or brew) was found.\n' >&2
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        printf 'Git installation did not succeed.\n' >&2
        exit 1
    fi
    printf 'Git installed successfully.\n'
fi

if [[ -e "$REPO_DIR" ]]; then
    if [[ ! -d "$REPO_DIR/.git" ]]; then
        printf 'Clone destination already exists and is not a Git checkout: %s\n' "$REPO_DIR" >&2
        exit 1
    fi
    REPO_ORIGIN="$(git -C "$REPO_DIR" remote get-url origin)"
    if [[ "$REPO_ORIGIN" != "$REPO_URL" ]]; then
        printf 'Existing checkout at %s has unexpected origin: %s\n' "$REPO_DIR" "$REPO_ORIGIN" >&2
        exit 1
    fi
    printf 'Using existing checkout at %s.\n' "$REPO_DIR"
else
    printf 'Cloning %s into %s.\n' "$REPO_URL" "$REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
fi

# Enter the checkout before resolving paths to deployment artifacts.
cd "$REPO_DIR"
SCRIPT_DIR="$(pwd)"
K8S_DIR="$SCRIPT_DIR/k8s"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
ENDPOINT_TIMEOUT="${ENDPOINT_TIMEOUT:-60}"
LAUNCH_SERVICE="${LAUNCH_SERVICE:-true}"
KUBECTL=(kubectl --context="$MINIKUBE_PROFILE")

# Fail early with a clear message if a required CLI or the manifests are missing.
for command in docker minikube kubectl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    fi
done

if [[ ! -d "$K8S_DIR" ]]; then
    printf 'Kubernetes manifests directory not found: %s\n' "$K8S_DIR" >&2
    exit 1
fi

# Ensure Docker daemon is active before starting Minikube with the Docker driver.
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker; then
    printf 'Starting Docker service...\n'
    sudo systemctl start docker.socket docker.service
fi

# Start the selected profile with the Docker driver and Docker runtime so docker-env works reliably.
printf 'Starting Minikube profile "%s" with the Docker driver...\n' "$MINIKUBE_PROFILE"
minikube --profile "$MINIKUBE_PROFILE" start --driver=docker --container-runtime=docker

# Export the Docker connection settings for this shell; builds below then target Minikube.
printf 'Configuring Docker to use Minikube profile "%s"...\n' "$MINIKUBE_PROFILE"
eval "$(minikube --profile "$MINIKUBE_PROFILE" docker-env --shell=bash)"

# Avoid BuildKit's sidecar builder, which fails with this Docker-over-SSH daemon.
export DOCKER_BUILDKIT=0

# Keep these tags aligned with the image names referenced by the Kubernetes deployments.
images=(backend:latest studentportfolio:latest transactions:latest)
contexts=(backend studentportfolio transactions)

# Build each application image in the Minikube Docker daemon, not the host daemon.
for index in "${!images[@]}"; do
    printf 'Building %s from %s...\n' "${images[$index]}" "${contexts[$index]}"
    docker build --tag "${images[$index]}" "$SCRIPT_DIR/${contexts[$index]}"
done

# Confirm the built tags are visible from the Minikube node before applying workloads.
printf 'Verifying application images inside the Minikube node...\n'
for image in "${images[@]}"; do
    minikube --profile "$MINIKUBE_PROFILE" ssh -- docker image inspect "$image" >/dev/null
    printf '  Verified %s\n' "$image"
done

# Apply every manifest in the directory so Services, config, storage, and workloads stay in sync.
printf 'Applying Kubernetes manifests from %s...\n' "$K8S_DIR"
"${KUBECTL[@]}" apply --filename "$K8S_DIR"

# Restart deployments so their pods are recreated with the locally built image tags.
printf 'Restarting application deployments to use the locally built images...\n'
"${KUBECTL[@]}" rollout restart deployment/nginx deployment/studentportfolio \
    deployment/backend deployment/transactions

# Wait for each deployment and the MongoDB StatefulSet to finish rolling out.
printf 'Waiting for application deployments and MongoDB...\n'
for deployment in nginx studentportfolio backend transactions; do
    "${KUBECTL[@]}" rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
done
"${KUBECTL[@]}" rollout status statefulset/mongo --timeout="$ROLLOUT_TIMEOUT"

# Require the ten baseline pods; HPAs may legitimately add more than ten.
pods="$("${KUBECTL[@]}" get pods --no-headers \
    --selector='app in (nginx,studentportfolio,backend,transactions,mongo)')"
pod_count="$(printf '%s\n' "$pods" | awk 'NF { count++ } END { print count+0 }')"
if [[ "$pod_count" -lt 10 ]]; then
    printf 'Expected at least 10 application pods, found %s:\n%s\n' "$pod_count" "$pods" >&2
    exit 1
fi

# Poll until each Service selects at least one ready pod endpoint.
printf 'Checking Service endpoints...\n'
for service in nginx studentportfolio backend transactions mongo; do
    endpoints=""
    for ((elapsed = 0; elapsed < ENDPOINT_TIMEOUT; elapsed += 2)); do
        endpoints="$("${KUBECTL[@]}" get endpoints "$service" \
            --output=jsonpath='{.subsets[*].addresses[*].ip}')"
        if [[ -n "$endpoints" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "$endpoints" ]]; then
        printf 'Service %s has no ready endpoints after %ss.\n' "$service" "$ENDPOINT_TIMEOUT" >&2
        exit 1
    fi
    printf '  %s: %s\n' "$service" "$endpoints"
done

# Show the resulting resources and launch the public Nginx Service.
printf '\nAll ten baseline pods passed their workload rollouts; %s application pods are present:\n' \
    "$pod_count"
"${KUBECTL[@]}" get pods \
    --selector='app in (nginx,studentportfolio,backend,transactions,mongo)' --output=wide
"${KUBECTL[@]}" get services nginx studentportfolio backend transactions mongo --output=wide

if [[ "$LAUNCH_SERVICE" == "true" ]]; then
    printf '\nLaunching Nginx service via Minikube (keep this terminal open while testing)...\n'
    minikube --profile "$MINIKUBE_PROFILE" service nginx
fi