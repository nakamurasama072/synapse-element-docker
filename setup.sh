#!/bin/bash

# Colored outputs
log() {
  echo "[INFO] $1"
}

hint() {
  echo -e "\033[36m[NOTE] $1\033[0m"
}

warning() {
  echo -e "\033[33m[WARNING] $1\033[0m"
}

fail() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
  exit 1
}

# check if user is root
check_root_permission() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "This script must be run with sudo/root privileges (example: sudo bash setup.sh)."
  fi
}

# verify if docker is installed
verify_docker_installation() {
  log "Verifying existing docker installation..."
  # I did not use "docker --version" here as some admins may use "alias docker=podman" in .*shrc
  if command -v docker &> /dev/null; then
    log "Docker is installed."
  else
    log "Unable to find existing installation of docker."
    hint "To install docker, please read https://docs.docker.com/engine/install for more information."
    fail "Docker not found on this host. Please install it first."
  fi
}

# verify firewall installation
verify_firewall_installation() {
  log "Verifying firewall installation..."
  if command -v ufw &> /dev/null; then
    log "ufw detected (Debian/Ubuntu)."
    FIREWALL_MANAGER="ufw"
  elif command -v firewall-cmd &> /dev/null; then
    log "firewall-cmd detected (RHEL/CentOS)."
    FIREWALL_MANAGER="firewall-cmd"
  else
    warning "No supported firewall (ufw/firewall-cmd) found. Firewall rules will be skipped."
    FIREWALL_MANAGER="none"
  fi
}

# generate home-server configuration file
generate_synapse_config() {
  # TODO: Use mirrors when unable to pull from docker.io (for users in China mainland)
  docker run -it --rm \
  -v $1:/data \
  -e SYNAPSE_SERVER_NAME=$2 \
  -e SYNAPSE_REPORT_STATS=yes \
  matrixdotorg/synapse:latest generate
}

# change directory to designated path
change_directory() {
  # TODO: add support for relative paths
  local path="$1"
  log "Changing directory to ${path}..."

  # if path does not exist
  if [[ ! -d "${path}" ]]; then
    warning "${path} does not exist. Creating..."
    mkdir -p "${path}"
  fi

  cd "${path}" || fail "Failed to change directory to ${path}. Please check if the path is correct and you have permission to access it."
}

# get installation path of synapse
get_synapse_installation_path() {
  local destination
  hint "Synapse will be installed to /opt/matrix/synapse_data by default." >&2
  read -r -p "Please enter the path you wish to install synapse (optional): " destination

  # TODO: Validate input
  # No input, use default installation path instead
  if [[ -z "${destination}" ]]; then
    destination="/opt/matrix/synapse_data"
  fi

  echo "$destination"
}

# get name of synapse server
get_server_name() {
  local server_name
  hint "You must specify a name for your server. It should be FQDN (Fully Qualified Domain Name), e.g. synapse.testinst.net" >&2
  hint "Please note that you cannot change your server name after generating the configuration file. If you want to change it, you will have to regenerate the configuration file." >&2
  read -r -p "Please enter the name of your server: " server_name

  # Empty name
  if [[ -z "${server_name}" ]]; then
    fail "No server name specified. Please run the script again for setup."
  fi

  # Invalid server name
  if ! [[ "${server_name}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
		fail "Invalid server name '${server_name}'. Use lowercase letters (a-z), numbers (0-9), hyphen (-) or dot (.)."
	fi

  echo "${server_name}"
}

# get the port that synapse will run on
get_running_port() {
  local port
  hint "The script is now attempting to set up the running port for synapse." >&2
  read -r -p "Please enter the port that synapse will run on (default: 8008): " port

  # No input, use default port instead
  if [[ -z "${port}" ]]; then
    port=8008
  elif ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "Invalid port '${port}'. Please enter a number between 1 and 65535."
  fi

  echo "${port}"
}

# Add enable_registration configuration to homeserver.yaml
enable_registration() {
  sed -i '/# vim:ft=yaml/i \
enable_registration: true\
enable_registration_without_verification: true' "$1/homeserver.yaml"
}

# Get the port that element-web will run on
get_element_web_port() {
  local port

  hint "The script is now attempting to set up the running port for element-web." >&2
  read -r -p "Please enter the port that element-web will run on (default: 8009): " port

  # No input, use default port instead
  if [[ -z "${port}" ]]; then
    port=8009
  elif ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    fail "Invalid port '${port}'. Please enter a number between 1 and 65535."
  fi

  echo "${port}"
}

# Ensure a host port is not already in use
check_port_availability() {
  local port="$1"
  local service_name="$2"

  note "Checking if port ${port} is available for ${service_name}..."

  # Using ss
  if command -v ss &> /dev/null; then
    if ss -ltnH | awk '{print $4}' | grep -Eq "(:|\])${port}$"; then
      fail "Port ${port} is already in use on this host. Please choose another port for ${service_name}."
    fi
  # No ss, using netstat as fallback
  elif command -v netstat &> /dev/null; then
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${port}$"; then
      fail "Port ${port} is already in use on this host. Please choose another port for ${service_name}."
    fi
  else
    warning "Unable to verify whether port ${port} is in use (missing ss/netstat). Continuing without occupancy check."
  fi
}

# Open firewall ports for synapse and element-web
open_firewall_ports() {
  local synapse_port="$1"
  local element_port="$2"

  # firewall not found or unsupported (e.g. iptables), skip firewall configuration
  if [[ "${FIREWALL_MANAGER}" == "none" ]]; then
    warning "Skipping firewall rules: no or unsupported firewall found."
    return
  fi

  log "Opening port ${synapse_port}/tcp and 8448/tcp for synapse..."
  log "Opening port ${element_port}/tcp for element-web..."

  # ufw
  if [[ "${FIREWALL_MANAGER}" == "ufw" ]]; then
    ufw allow "${synapse_port}/tcp" || fail "Failed to open port ${synapse_port} with ufw."
    ufw allow 8448/tcp || fail "Failed to open port 8448 with ufw." # Federation port for synapse
    ufw allow "${element_port}/tcp" || fail "Failed to open port ${element_port} with ufw."
  # firewall-cmd
  elif [[ "${FIREWALL_MANAGER}" == "firewall-cmd" ]]; then
    firewall-cmd --permanent --add-port="${synapse_port}/tcp" || fail "Failed to open port ${synapse_port} with firewall-cmd."
    firewall-cmd --permanent --add-port=8448/tcp || fail "Failed to open port 8448 with firewall-cmd." # Federation port for synapse
    firewall-cmd --permanent --add-port="${element_port}/tcp" || fail "Failed to open port ${element_port} with firewall-cmd."
    firewall-cmd --reload || fail "Failed to reload firewall rules."
  fi

  log "Firewall ports opened successfully."
}

# Generate docker-compose.yaml file for synapse, using the port, server name and path specified by user
generate_docker_compose() {
  cat <<EOF > "$1/docker-compose.yaml"
# version: "3.3"
# Please refer to: https://blog.laoda.de/archives/docker-compose-install-matrix-element
# Reminder: You might need a translator for reading this site.

services:
  synapse:
    image: "matrixdotorg/synapse:latest"
    container_name: "synapse"
    restart: unless-stopped
    ports:
      - "$2:8008"
    volumes:
      - "$1:/data"
    environment:
      VIRTUAL_HOST: "$3"
      VIRTUAL_PORT: "8008"
      LETSENCRYPT_HOST: "$3"
      SYNAPSE_SERVER_NAME: "$3"
      SYNAPSE_REPORT_STATS: "no"
  element-web:
    ports:
      - "$4:80"
    image: vectorim/element-web
    container_name: "element-web"
    restart: unless-stopped
EOF
}

# Start docker containers using docker compose or docker-compose (fallback)
start_docker_containers() {
  if command -v docker-compose &> /dev/null; then
    docker-compose up -d
  elif command -v docker &> /dev/null; then
    docker compose up -d
  else
    fail "docker-compose or docker is not installed. Please install it first and run the script again."
  fi
}

# The main function.
main() {
  hint "Welcome to the setup script for synapse and element-web docker containers!"
  hint "This script will guide you through the setup process and generate necessary configuration files for synapse and element-web. Please follow the instructions and provide the required information when prompted."
  hint "Please note that this script may not stop in a few cases when you provide invalid input. Please exit the script manually and run it again with correct input if you encounter such issue."
  hint "Before we start, please make sure that your basic firewall configuration is properly set up."
  log "Verifying that you are root..."
  check_root_permission
  verify_docker_installation
  verify_firewall_installation

  # Generate configuration file for synapse
  synapse_destination="$(get_synapse_installation_path)"
  server_name="$(get_server_name)"
  change_directory "${synapse_destination}"
  generate_synapse_config "${synapse_destination}" "${server_name}"

  # Additional configuration for synapse
  running_port="$(get_running_port)"
  enable_registration "${synapse_destination}"
  # change_running_port "${running_port}" "${synapse_destination}"
  element_web_port="$(get_element_web_port)"
  if [[ "${running_port}" == "${element_web_port}" ]]; then
    fail "Port conflict detected: synapse and element-web cannot use the same port (${running_port})."
  elif [[ "${running_port}" == 8448 ]]; then
    fail "Port conflict detected: synapse's federation port (8448) cannot be used as its running port. Please choose another port for synapse."
  elif [[ "${element_web_port}" == 8448 ]]; then
    fail "Port conflict detected: synapse's federation port (8448) cannot be used as the running port for element-web. Please choose another port for element-web."
  fi
  check_port_availability "${running_port}" "synapse"
  check_port_availability "${element_web_port}" "element-web"
  open_firewall_ports "${running_port}" "${element_web_port}"

  # Generate docker-compose.yaml file for synapse and element-web
  log "Generating docker-compose.yaml file for synapse and element-web..."
  generate_docker_compose "${synapse_destination}" "${running_port}" "${server_name}" "${element_web_port}"
  log "Generation complete. Now attempting to start synapse and element-web using docker-compose..."
  # Start synapse and element-web using docker-compose
  start_docker_containers
}

# Executes from here
main "$@"
