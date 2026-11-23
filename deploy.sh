#!/usr/bin/env bash

# Stop immediately if an unset variable is referenced or an external command fails.
set -eu
set -o pipefail

# ==============================================================================
# 1. Install/check Git, then clone the deployment repository
# ==============================================================================
REPO_URL="https://github.com/Michaelo233/module5-part3-Michael.git"
REPO_NAME="module5-part3-Michael"
REPO_DIR="${DEPLOY_REPO_DIR:-$PWD/$REPO_NAME}"

if command -v git &> /dev/null; then
    echo "Git is already installed."
else
    if command -v apt-get &> /dev/null; then
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update && apt-get install -y git
        elif command -v sudo &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y git
        else
            echo "Git is missing and sudo is not available to install it."
            exit 1
        fi
    elif command -v brew &> /dev/null; then
        brew install git
    else
        echo "Git is missing and no supported package manager (apt-get or brew) was found."
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        echo "Git installation did not succeed."
        exit 1
    fi
    echo "Git installed successfully."
fi

if [ -e "$REPO_DIR" ]; then
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "Clone destination already exists and is not a Git checkout: $REPO_DIR"
        exit 1
    fi
    REPO_ORIGIN="$(git -C "$REPO_DIR" remote get-url origin)"
    if [ "$REPO_ORIGIN" != "$REPO_URL" ]; then
        echo "Existing checkout at $REPO_DIR has unexpected origin: $REPO_ORIGIN"
        exit 1
    fi
    echo "Using existing checkout at $REPO_DIR."
else
    echo "Cloning $REPO_URL into $REPO_DIR."
    git clone "$REPO_URL" "$REPO_DIR"
fi

# Enter the cloned repository only after cloning has completed.
cd "$REPO_DIR"
SCRIPT_DIR="$(pwd)"
LOCAL_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_FILE="$LOCAL_COMPOSE_FILE"
DOCKER_CLI="docker"

# ==============================================================================
# 2. Validate Docker/Compose and ensure the Docker daemon is available
# ==============================================================================
# WSL may have a separate Linux Docker daemon from Docker Desktop on Windows.
# Prefer Docker Desktop's CLI there so port checks and deployment use the same engine.
if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v docker.exe &> /dev/null; then
    DOCKER_CLI="$(command -v docker.exe)"
    if ! command -v wslpath &> /dev/null; then
        echo "wslpath is required to use Docker Desktop from WSL."
        exit 1
    fi
    COMPOSE_FILE="$(wslpath -w "$LOCAL_COMPOSE_FILE")"
    echo "Using Docker Desktop from WSL."
fi

# Check whether the Docker CLI is available.
if ! command -v "$DOCKER_CLI" &> /dev/null; then
    echo "Docker is not installed."
    exit 1
fi

# Route all Docker commands through the selected CLI.
docker() {
    "$DOCKER_CLI" "$@"
}

# Check whether the Docker Compose v2 plugin is available.
if ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed."
    exit 1
fi

# Verify the compose file exists at the corrected repository-root path.
if [ ! -f "$LOCAL_COMPOSE_FILE" ]; then
    echo "docker-compose.yml not found in $SCRIPT_DIR."
    exit 1
fi

# Check whether the Docker daemon is reachable before attempting deployment.
if ! docker info &> /dev/null; then
    if [ -n "${WSL_DISTRO_NAME:-}" ] && command -v powershell.exe &> /dev/null; then
        echo "Docker Desktop is not reachable. Attempting to start it from WSL..."
        if powershell.exe -NoProfile -NonInteractive -Command '$exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"; if (Test-Path $exe) { Start-Process -FilePath $exe } else { exit 1 }'; then
            attempts=0
            while [ "$attempts" -lt 60 ]; do
                if docker info &> /dev/null; then
                    echo "Docker Desktop is running."
                    break
                fi
                attempts=$((attempts + 1))
                sleep 2
            done
        else
            echo "Could not start Docker Desktop automatically."
        fi
    fi

    if ! docker info &> /dev/null; then
        echo "Docker is installed, but the Docker daemon is not running or reachable. Start Docker Desktop (or another Docker engine) and rerun the script."
        exit 1
    fi
fi

# ==============================================================================
# 3. Check required host ports before deployment
# ==============================================================================
# Allow a port already published by this Compose project's running service.
check_port() {
    local port="$1"
    local service="$2"
    local listeners

    if command -v ss &> /dev/null; then
        listeners="$(ss -H -ltn "sport = :$port")"
    else
        listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    fi
    if [ -n "$listeners" ]; then
        if [ -n "$(docker compose -f "$COMPOSE_FILE" ps -q "$service")" ]; then
            echo "Port $port is already used by this project's running $service service."
        else
            echo "Required port $port is already in use by another process."
            exit 1
        fi
    fi
}

if ! command -v ss &> /dev/null && ! command -v lsof &> /dev/null; then
    echo "Cannot check required ports: install ss (iproute2) or lsof and rerun the script."
    exit 1
fi

# ==============================================================================
# 4. Build & deploy with compose
# ==============================================================================
check_port 3000 transactions
check_port 5000 backend
check_port 80 nginx

# Build images and start all services in detached mode.
docker compose -f "$COMPOSE_FILE" up -d --build

# ==============================================================================
# 5. Perform health checks & list images
# ==============================================================================
# Wait for an HTTP response from a service. Any HTTP status confirms it is reachable.
wait_for_http() {
    local name="$1"
    local url="$2"
    local service="$3"
    local attempts=30

    while [ "$attempts" -gt 0 ]; do
        if curl -sS -o /dev/null --max-time 3 "$url" 2>/dev/null; then
            echo "$name is responding at $url."
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 2
    done

    echo "$name did not respond at $url."
    docker compose -f "$COMPOSE_FILE" logs --tail=80 "$service"
    return 1
}

# The transactions root currently returns HTTP 404, so check reachability rather than HTTP success status.
wait_for_http "Transactions service" "http://localhost:3000/" transactions
wait_for_http "Backend service" "http://localhost:5000/" backend

# Nginx is the public entry point for the web application.
wait_for_http "Nginx" "http://localhost:80/" nginx

# Confirm that Compose reports the deployed services before collecting validation details.
docker compose -f "$COMPOSE_FILE" ps

# Print every Docker image available locally.
docker images

# ==============================================================================
# 6. Show docker ps & collect the Nginx container ID as a variable
# ==============================================================================
# List running containers before looking up the Nginx container ID.
docker ps

# Select the running Nginx container for this Compose project.
NGINX_CONTAINER_ID=$(docker compose -f "$COMPOSE_FILE" ps -q nginx)
echo "Nginx Container ID: $NGINX_CONTAINER_ID"

if [ -z "$NGINX_CONTAINER_ID" ]; then
    echo "Nginx container is not running."
    exit 1
fi

# ==============================================================================
# 7. Validate the portfolio page renders at the public URL
# ==============================================================================
if curl -fsS --max-time 5 http://localhost:80/ | grep -qF "Michael Obikwere - Student Portfolio"; then
    echo "Portfolio page rendered successfully at http://localhost/."
else
    echo "Portfolio page did not render the expected title."
    docker compose -f "$COMPOSE_FILE" logs --tail=80 nginx studentportfolio
    exit 1
fi

# ==============================================================================
# 8. Ensure jq is installed, inspect nginx:alpine, and save output to nginx-logs
# ==============================================================================
if ! command -v jq &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update && apt-get install -y jq
        else
            sudo apt-get update && sudo apt-get install -y jq
        fi
    elif command -v brew &> /dev/null; then
        brew install jq
    else
        echo "jq is required but is not installed. Install jq and rerun this script."
        exit 1
    fi
fi

# Serialize Docker's inspection data for the nginx:alpine image to a file.
docker image inspect nginx:alpine > "$SCRIPT_DIR/nginx-logs"

# ==============================================================================
# 9. Extract and echo the values of specified keys from nginx-logs
# ==============================================================================
# Label and print the repository tags recorded in nginx-logs.

echo "RepoTags:"
jq '.[0].RepoTags' "$SCRIPT_DIR/nginx-logs"

# Label and print the image creation timestamp.
echo "Created:"
jq '.[0].Created' "$SCRIPT_DIR/nginx-logs"

# Label and print the operating system recorded for the image.
echo "Os:"
jq '.[0].Os' "$SCRIPT_DIR/nginx-logs"

# Label and print the image configuration object.
echo "Config:"
jq '.[0].Config' "$SCRIPT_DIR/nginx-logs"

# Label and print only the exposed port mapping.
echo "ExposedPorts:"
jq '.[0].Config.ExposedPorts' "$SCRIPT_DIR/nginx-logs"