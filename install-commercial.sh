#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Orkalab Commercial Installer
#  Version: 1.1.3
#  
#  This installer sets up Orkalab from pre-built Docker images.
#  No source code is distributed - only compiled production images.
#
#  Features (matching install.sh):
#  • License validation with JSON format license files
#  • Network configuration (DHCP, NAT, IP forwarding)
#  • Proxmox API integration with auto-detection
#  • SSL certificate generation
#  • Database setup (PostgreSQL, Guacamole)
#  • Admin user creation
#  • Comprehensive error handling
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# Capture script directory BEFORE any cd commands
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
INSTALL_DIR="/opt/orkalab"
DOCKER_HUB_USER="cursedscropio"
VERSION_URL="https://raw.githubusercontent.com/CursedScorpio/OrkaLab/main/version.json"
COMPOSE_URL="https://raw.githubusercontent.com/CursedScorpio/OrkaLab/main/docker-compose.yml"
GUAC_INITDB_URL="https://raw.githubusercontent.com/CursedScorpio/OrkaLab/main/guacamole/initdb.sql"
LOG_FILE="/var/log/orkalab-commercial-install.log"
DEBUG_MODE=false

# R2 template download (read-only) – used only inside installer
R2_ENDPOINT="https://3bfdd53155d3fd8539e6b122d5a12cd9.r2.cloudflarestorage.com"
R2_BUCKET="linux-proxmox"
R2_ACCESS_KEY_ID="c9b19d59f8344ebc432a27554060a07a"
R2_SECRET_ACCESS_KEY="b173c96c7708bd75aab3a2f600382692902993240fbc140c5a9b66cc87b12ab0"

# Minimal embedded template list (no external manifests)
TEMPLATE_JSON=$(cat <<'EOF'
[
    {
        "id": "ubuntu-22.04-server",
        "name": "Ubuntu 22.04 LTS (Base)",
        "filename": "templates/free/ubuntu-22.04-server.qcow2",
        "vmid_default": 101,
        "template_name": "ubuntu-22.04-orkalab",
        "storage_default": "local-lvm",
        "memory": 2048,
        "cores": 2,
        "default_user": "root",
        "default_pass": "Orkalab_123",
        "tier": "free"
    }
]
EOF
)

# Parse command line arguments (hidden --debug flag)
for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG_MODE=true
            shift
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════════════════════
#  Helper Functions
# ═══════════════════════════════════════════════════════════════════════════════

# Log function with file and console output
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Debug log - only shows in debug mode
debug_log() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
    else
        echo "$1" >> "$LOG_FILE"
    fi
}

# Run command with debug output
run_command() {
    local cmd="$1"
    local description="$2"
    
    # Ensure non-interactive mode for apt commands
    if echo "$cmd" | grep -q "apt-get"; then
        cmd="DEBIAN_FRONTEND=noninteractive $cmd"
    fi
    
    debug_log "Running: $cmd"
    
    if [ "$DEBUG_MODE" = true ]; then
        # In debug mode, show everything
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}EXECUTING: $description${NC}"
        echo -e "${MAGENTA}COMMAND: $cmd${NC}"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
        local exit_code=${PIPESTATUS[0]}
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}EXIT CODE: $exit_code${NC}"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        return $exit_code
    else
        # Normal mode, hide output
        eval "$cmd" >> "$LOG_FILE" 2>&1
        return $?
    fi
}

# Error exit with debug info
error_exit() {
    log "${RED}[✗] ERROR: $1${NC}"
    log "${YELLOW}Check logs: $LOG_FILE${NC}"
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${MAGENTA}Last 50 lines of log:${NC}"
        echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        tail -n 50 "$LOG_FILE"
    fi
    exit 1
}

print_banner() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}██████╗ ██████╗ ██╗  ██╗ █████╗ ██╗      █████╗ ██████╗${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}██╔═══██╗██╔══██╗██║ ██╔╝██╔══██╗██║     ██╔══██╗██╔══██╗${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}██║   ██║██████╔╝█████╔╝ ███████║██║     ███████║██████╔╝${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}██║   ██║██╔══██╗██╔═██╗ ██╔══██║██║     ██╔══██║██╔══██╗${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA}╚██████╔╝██║  ██║██║  ██╗██║  ██║███████╗██║  ██║██████╔╝${NC}                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${MAGENTA} ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                    ${BOLD}Cybersecurity Learning Platform${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                         ${BLUE}Commercial Installer${NC}                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[INFO] $1" >> "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    echo "[✓] $1" >> "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    echo "[✗] ERROR: $1" >> "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    echo "[!] WARNING: $1" >> "$LOG_FILE"
}

print_step() {
    echo -e "${MAGENTA}[STEP $1]${NC} $2"
    echo "[STEP $1] $2" >> "$LOG_FILE"
}

# Generate random password (hex for better security, matching install.sh)
generate_password() {
    openssl rand -hex 32
}

# Ensure AWS CLI is available for R2 downloads
ensure_awscli() {
    if command -v aws >/dev/null 2>&1; then
        return
    fi
    print_status "Installing awscli for template download..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -y -qq awscli >> "$LOG_FILE" 2>&1 || error_exit "Failed to install awscli"
    print_success "awscli installed"
}

# Pick a VMID; prefer provided default, otherwise next free
pick_vmid() {
    local preferred="$1"
    if ! qm status "$preferred" >/dev/null 2>&1; then
        echo "$preferred"
        return
    fi
    local nextid
    nextid=$(pvesh get /cluster/nextid 2>/dev/null || true)
    if [ -n "$nextid" ]; then
        echo "$nextid"
    else
        # Fallback: find max+1
        local maxid
        maxid=$(qm list | awk 'NR>1 {print $1}' | sort -n | tail -1)
        echo $((maxid + 1))
    fi
}

# Download and import a template from R2 into Proxmox
download_and_import_template() {
    local id="$1"
    local name="$2"
    local filename="$3"
    local default_vmid="$4"
    local template_name="$5"
    local storage_default="$6"
    local memory="$7"
    local cores="$8"
    local default_user="$9"
    local default_pass="${10}"

    echo ""
    print_status "Template: $name"
    print_status "Default credentials: ${default_user}/${default_pass}"

    # Check if template already exists by name
    if qm list | awk 'NR>1 {print $2}' | grep -Fx "$template_name" >/dev/null 2>&1; then
        print_warning "Template '$template_name' already exists in Proxmox."
        read -p "Create another copy anyway? [y/N]: " CREATE_DUPLICATE </dev/tty
        if [[ ! "$CREATE_DUPLICATE" =~ ^[Yy]$ ]]; then
            print_success "Skipping - using existing template."
            return
        fi
        print_status "Will create a new copy with different VMID..."
    fi

    # Choose storage
    read -p "Proxmox storage to use [$storage_default]: " STORAGE_INPUT </dev/tty
    local storage="${STORAGE_INPUT:-$storage_default}"

    # Pick VMID
    local vmid
    vmid=$(pick_vmid "$default_vmid")
    print_status "Using VMID: $vmid"

    ensure_awscli
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"

    local tmp_dir="/tmp/orkalab-templates"
    mkdir -p "$tmp_dir"
    local target_file="$tmp_dir/$(basename "$filename")"

    print_status "Downloading from R2 (private bucket)..."
    if ! aws s3 cp "s3://$R2_BUCKET/$filename" "$target_file" --endpoint-url "$R2_ENDPOINT" --no-progress; then
        error_exit "Failed to download template $name"
    fi

    # Import to Proxmox
    print_status "Creating VM $vmid ($template_name)..."
    qm create "$vmid" --name "$template_name" --memory "$memory" --cores "$cores" --agent 1 --ostype l26 --scsihw virtio-scsi-pci >> "$LOG_FILE" 2>&1

    print_status "Importing disk to storage '$storage'..."
    qm importdisk "$vmid" "$target_file" "$storage" >> "$LOG_FILE" 2>&1

    # Attach disk
    qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "${storage}:vm-${vmid}-disk-0" --boot order=scsi0 >> "$LOG_FILE" 2>&1

    # Cloud-init
    qm set "$vmid" --ide2 "${storage}:cloudinit" --serial0 socket --vga serial0 >> "$LOG_FILE" 2>&1

    # Mark as template
    qm template "$vmid" >> "$LOG_FILE" 2>&1

    print_success "Imported and templated: $template_name (VMID $vmid)"
    rm -f "$target_file"
}

# Offer template download/ import flow (free + premium-ready, but currently single Ubuntu)
prompt_template_downloads() {
    print_section "Optional: Download VM Templates"

    echo "Available template:"
    echo "  • Ubuntu 22.04 LTS (cloud-init)"
    echo "    User/Pass: root / Orkalab_123"
    echo ""

    read -p "Download and import the Ubuntu template now? [Y/n]: " DL_CHOICE
    if [[ "$DL_CHOICE" =~ ^[Nn]$ ]]; then
        print_warning "Skipping template download"
        return
    fi

    # Parse embedded JSON and process entries (currently one)
    echo "$TEMPLATE_JSON" | jq -c '.[]' | while read -r item; do
        local id name filename vmid template_name storage_default memory cores tier user pass
        id=$(echo "$item" | jq -r '.id')
        name=$(echo "$item" | jq -r '.name')
        filename=$(echo "$item" | jq -r '.filename')
        vmid=$(echo "$item" | jq -r '.vmid_default')
        template_name=$(echo "$item" | jq -r '.template_name')
        storage_default=$(echo "$item" | jq -r '.storage_default')
        memory=$(echo "$item" | jq -r '.memory')
        cores=$(echo "$item" | jq -r '.cores')
        tier=$(echo "$item" | jq -r '.tier')
        user=$(echo "$item" | jq -r '.default_user')
        pass=$(echo "$item" | jq -r '.default_pass')

        # Free tier is allowed for all licenses; premium would be gated later if added
        download_and_import_template "$id" "$name" "$filename" "$vmid" "$template_name" "$storage_default" "$memory" "$cores" "$user" "$pass"
    done
}

# Generate server fingerprint (matching install.sh)
generate_server_fingerprint() {
    local cpu_info=$(cat /proc/cpuinfo | grep 'model name' | head -1 | cut -d':' -f2 | xargs)
    local product_uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    
    if [ -z "$product_uuid" ]; then
        print_warning "Could not read motherboard UUID, using CPU-only fingerprint"
        local fingerprint_data="${cpu_info}"
    else
        local fingerprint_data="${cpu_info}|${product_uuid}"
    fi
    
    local fingerprint=$(echo -n "$fingerprint_data" | sha256sum | cut -d' ' -f1 | cut -c1-32)
    echo "$fingerprint"
}

# Disable Proxmox enterprise repositories (matching install.sh)
disable_enterprise_repos() {
    local REPO_DISABLED=false
    
    # Handle .list format files
    for listfile in /etc/apt/sources.list.d/*enterprise*.list /etc/apt/sources.list.d/ceph*.list; do
        if [ -f "$listfile" ]; then
            if grep -q "^deb" "$listfile" 2>/dev/null; then
                sed -i 's/^deb/#deb/g' "$listfile"
                REPO_DISABLED=true
            fi
        fi
    done

    # Handle .sources format files
    for sourcefile in /etc/apt/sources.list.d/*enterprise*.sources /etc/apt/sources.list.d/ceph*.sources; do
        if [ -f "$sourcefile" ]; then
            mv "$sourcefile" "${sourcefile}.disabled" 2>/dev/null || true
            REPO_DISABLED=true
        fi
    done

    # Check main sources.list
    if [ -f /etc/apt/sources.list ]; then
        if grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
            sed -i 's|^deb.*enterprise.proxmox.com|#&|g' /etc/apt/sources.list
            REPO_DISABLED=true
        fi
    fi
    
    if [ "$REPO_DISABLED" = true ]; then
        echo "Disabled Proxmox enterprise repositories" >> "$LOG_FILE"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Pre-flight Checks
# ═══════════════════════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This installer must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect OS. This installer requires Debian/Ubuntu."
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
        print_warning "This installer is designed for Debian/Ubuntu. Your OS: $ID"
        read -p "Continue anyway? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

check_docker() {
    debug_log "Checking Docker installation..."
    if ! command -v docker &> /dev/null; then
        print_status "Docker not found. Installing Docker..."
        if [ "$DEBUG_MODE" = true ]; then
            curl -fsSL https://get.docker.com | sh 2>&1 | tee -a "$LOG_FILE"
        else
            curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
        fi
        systemctl enable docker >> "$LOG_FILE" 2>&1
        systemctl start docker >> "$LOG_FILE" 2>&1
        print_success "Docker installed"
    else
        DOCKER_VERSION=$(docker --version)
        debug_log "Docker version: $DOCKER_VERSION"
        print_success "Docker is installed"
    fi
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose V2 is required but not installed"
        exit 1
    fi
    COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    debug_log "Docker Compose version: $COMPOSE_VERSION"
    print_success "Docker Compose is available"
}

check_license() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Check for JSON format license file (matching install.sh)
    if [[ ! -f "$SCRIPT_DIR/license.lic" ]]; then
        # Generate fingerprint and show instructions
        FINGERPRINT=$(generate_server_fingerprint)
        
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}        NO LICENSE FOUND${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${CYAN}Orkalab can run with a commercial license or a free license.${NC}"
        echo ""
        echo "  1) I have a commercial license (yearly/perpetual)"
        echo "  2) Use FREE license (limited features)"
        echo ""
        
        read -p "Choose option [1-2]: " LICENSE_CHOICE
        
        case $LICENSE_CHOICE in
            2)
                echo ""
                print_status "Generating FREE license..."
                # Install jq if needed for JSON generation
                if ! command -v jq &> /dev/null; then
                    print_status "Installing jq for license generation..."
                    apt-get update -qq >> "$LOG_FILE" 2>&1
                    apt-get install -y -qq jq >> "$LOG_FILE" 2>&1
                fi
                generate_free_license_file "$FINGERPRINT"
                print_success "Free license generated"
                echo ""
                echo -e "${YELLOW}⚠️  FREE LICENSE LIMITATIONS:${NC}"
                echo "  • Sandbox mode only (no scenarios)"
                echo "  • Maximum 1 concurrent VM"
                echo "  • No save functionality"
                echo "  • Limited to 5 users"
                echo ""
                read -p "Continue with free license? [Y/n]: " CONFIRM_FREE
                if [[ "$CONFIRM_FREE" =~ ^[Nn]$ ]]; then
                    echo "Installation cancelled."
                    exit 0
                fi
                ;;
            1|*)
                echo ""
                echo -e "${GREEN}Step 1: Send this Server Fingerprint to your vendor${NC}"
                echo ""
                echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
                echo -e "${CYAN}║  ${GREEN}${FINGERPRINT}${CYAN}  ║${NC}"
                echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${GREEN}Step 2: Receive license.lic file from vendor${NC}"
                echo ""
                echo -e "${GREEN}Step 3: Place license.lic next to install-commercial.sh and run again${NC}"
                echo ""
                
                # Save fingerprint
                mkdir -p "$INSTALL_DIR"
                echo "$FINGERPRINT" > "$INSTALL_DIR/server-fingerprint.txt"
                echo -e "${GREEN}✅ Fingerprint saved to: $INSTALL_DIR/server-fingerprint.txt${NC}"
                exit 1
                ;;
        esac
    fi
    
    # Install jq if needed for JSON parsing
    if ! command -v jq &> /dev/null; then
        print_status "Installing jq for license parsing..."
        apt-get update -qq >> "$LOG_FILE" 2>&1
        apt-get install -y -qq jq >> "$LOG_FILE" 2>&1
    fi
    
    # Parse JSON license file (matching install.sh format)
    LICENSE_KEY=$(jq -r '.license_key' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    CUSTOMER=$(jq -r '.customer' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    LICENSE_TYPE=$(jq -r '.license_type' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    LICENSE_FINGERPRINT=$(jq -r '.server_fingerprint' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    
    # Validate fields exist
    if [ "$LICENSE_KEY" = "null" ] || [ -z "$LICENSE_KEY" ]; then
        print_error "Invalid license file: missing license_key"
        exit 1
    fi
    
    # Check for free license
    if [ "$LICENSE_TYPE" = "free" ]; then
        VERIFICATION_HASH=$(jq -r '.verification_hash' "$SCRIPT_DIR/license.lic" 2>/dev/null)
        if [ "$VERIFICATION_HASH" = "null" ] || [ -z "$VERIFICATION_HASH" ]; then
            print_error "Invalid free license file: missing verification_hash"
            exit 1
        fi
        
        # Verify free license hash
        SERVER_FINGERPRINT=$(generate_server_fingerprint)
        EXPECTED_HASH=$(echo -n "${SERVER_FINGERPRINT}${LICENSE_KEY}orkalab-free" | sha256sum | cut -d' ' -f1)
        
        # Support both 32-char and 64-char hashes
        EXPECTED_HASH_SHORT="${EXPECTED_HASH:0:32}"
        if [ "$VERIFICATION_HASH" != "$EXPECTED_HASH" ] && [ "$VERIFICATION_HASH" != "$EXPECTED_HASH_SHORT" ]; then
            print_error "Invalid free license: verification failed"
            exit 1
        fi
        
        print_success "License Key: $LICENSE_KEY"
        print_success "Customer: $CUSTOMER"
        print_success "Type: FREE"
        print_success "Fingerprint: Verified"
        print_warning "Free license - limited features enabled"
        print_success "License validation passed"
        return
    fi
    
    # Commercial license validation
    SIGNATURE=$(jq -r '.signature' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    MAINTENANCE_EXPIRES=$(jq -r '.maintenance_expires' "$SCRIPT_DIR/license.lic" 2>/dev/null)
    
    if [ "$SIGNATURE" = "null" ] || [ -z "$SIGNATURE" ]; then
        print_error "Invalid license file: missing signature"
        exit 1
    fi
    
    # Generate server fingerprint and verify match
    SERVER_FINGERPRINT=$(generate_server_fingerprint)
    
    if [ "$LICENSE_FINGERPRINT" != "$SERVER_FINGERPRINT" ]; then
        print_error "License fingerprint mismatch!"
        echo "   Expected: $LICENSE_FINGERPRINT"
        echo "   Server:   $SERVER_FINGERPRINT"
        print_error "License is not valid for this server"
        exit 1
    fi
    
    print_success "License Key: $LICENSE_KEY"
    print_success "Customer: $CUSTOMER"
    print_success "Type: $LICENSE_TYPE"
    print_success "Fingerprint: Verified"
    
    # Check license expiration for yearly licenses
    if [ "$LICENSE_TYPE" = "yearly" ]; then
        LICENSE_EXPIRES=$(jq -r '.license_expires' "$SCRIPT_DIR/license.lic" 2>/dev/null)
        TODAY=$(date +%Y-%m-%d)
        if [[ "$TODAY" > "$LICENSE_EXPIRES" ]]; then
            print_error "Yearly license expired on $LICENSE_EXPIRES. Please renew."
            exit 1
        else
            DAYS_LEFT=$(( ($(date -d "$LICENSE_EXPIRES" +%s) - $(date -d "$TODAY" +%s)) / 86400 ))
            print_success "License expires: $LICENSE_EXPIRES ($DAYS_LEFT days remaining)"
        fi
    fi
    
    # Check maintenance status
    if [ "$MAINTENANCE_EXPIRES" != "null" ] && [ -n "$MAINTENANCE_EXPIRES" ]; then
        TODAY=$(date +%Y-%m-%d)
        if [[ "$TODAY" > "$MAINTENANCE_EXPIRES" ]]; then
            print_warning "Maintenance: Expired on $MAINTENANCE_EXPIRES"
            print_warning "Software will work but updates/support unavailable"
        else
            DAYS_LEFT=$(( ($(date -d "$MAINTENANCE_EXPIRES" +%s) - $(date -d "$TODAY" +%s)) / 86400 ))
            print_success "Maintenance: Valid ($DAYS_LEFT days remaining)"
        fi
    fi
    
    print_success "License validation passed"
}

generate_free_license_file() {
    local fingerprint="$1"
    local license_key="OL-FREE-${fingerprint:0:8}"
    license_key=$(echo "$license_key" | tr '[:lower:]' '[:upper:]')
    
    # Create verification hash (matching install.sh method)
    local verification_hash=$(echo -n "${fingerprint}${license_key}orkalab-free" | sha256sum | cut -d' ' -f1)
    
    # Create free license file
    cat > "$SCRIPT_DIR/license.lic" << EOF
{
  "customer": "Free User (${fingerprint:0:8})",
  "features": {
    "builder_sandbox_enabled": true,
    "builder_scenario_enabled": false,
    "max_concurrent_vms": 1,
    "max_saves_per_user": 0,
    "max_users": 5,
    "sandbox_enabled": true,
    "saves_enabled": false,
    "scenarios_enabled": false
  },
  "issued_date": "$(date +%Y-%m-%d)",
  "license_key": "$license_key",
  "license_type": "free",
  "server_fingerprint": "$fingerprint",
  "verification_hash": "$verification_hash"
}
EOF
    chmod 600 "$SCRIPT_DIR/license.lic"
}

check_network() {
    print_status "Checking network connectivity..."
    
    if ! curl -s --connect-timeout 5 https://hub.docker.com > /dev/null; then
        print_error "Cannot connect to Docker Hub. Please check your internet connection."
        exit 1
    fi
    
    print_success "Network connectivity OK"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  System Detection (matching install.sh)
# ═══════════════════════════════════════════════════════════════════════════════

detect_system() {
    print_section "System Detection"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
    else
        OS="Unknown"
    fi
    
    CPU_CORES=$(nproc)
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    HOSTNAME=$(hostname)
    PRIMARY_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
    
    print_success "OS: $OS $OS_VERSION"
    print_success "CPU: $CPU_CORES cores"
    print_success "RAM: ${RAM_GB}GB"
    print_success "Disk: ${DISK_GB}GB free"
    print_success "IP: $PRIMARY_IP"
    
    # Minimum requirements check
    [ "$CPU_CORES" -lt 2 ] && { print_error "Need 2+ CPU cores"; exit 1; }
    [ "$RAM_GB" -lt 4 ] && { print_error "Need 4GB+ RAM"; exit 1; }
    [ "$DISK_GB" -lt 20 ] && { print_error "Need 20GB+ free disk space"; exit 1; }
    
    # Detect bridges
    BRIDGES=$(ip link show 2>/dev/null | grep -o 'vmbr[0-9]*' | sort -u)
    if [ -n "$BRIDGES" ]; then
        print_success "Proxmox bridges detected:"
        for bridge in $BRIDGES; do
            BRIDGE_IP=$(ip -4 addr show $bridge 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
            [ -n "$BRIDGE_IP" ] && echo "     • $bridge: $BRIDGE_IP"
        done
    fi
    
    # Detect DNS
    DNS_SERVERS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    DNS_SERVERS=${DNS_SERVERS:-8.8.8.8,8.8.4.4}
    DNS_PRIMARY=$(echo $DNS_SERVERS | cut -d',' -f1)
    DNS_SECONDARY=$(echo $DNS_SERVERS | cut -d',' -f2)
    DNS_SECONDARY=${DNS_SECONDARY:-8.8.4.4}
    
    print_success "DNS: $DNS_SERVERS"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Network Configuration (SDN VXLAN mode - no bridge selection needed)
# ═══════════════════════════════════════════════════════════════════════════════

configure_network() {
    print_step "1/8" "Configuring network..."
    
    # IP forwarding (required for SDN SNAT to work)
    print_status "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >> "$LOG_FILE" 2>&1
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p >> "$LOG_FILE" 2>&1
    print_success "IP forwarding enabled"
    
    # Note: With SDN VXLAN, we don't need:
    # - Bridge selection (VMs use SDN VNets)
    # - NAT/Masquerade rules (SDN handles SNAT per subnet)
    # - DHCP server (VMs get static IPs via cloud-init)
    print_success "SDN mode: Bridge/NAT configuration not required"
    print_status "VMs will use SDN VXLAN networks with automatic SNAT"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Installation Functions
# ═══════════════════════════════════════════════════════════════════════════════

create_directories() {
    print_step "3/8" "Creating installation directories..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/nginx/ssl"
    mkdir -p "$INSTALL_DIR/guacamole"
    mkdir -p "$INSTALL_DIR/data/postgres"
    mkdir -p "$INSTALL_DIR/data/guacamole"
    mkdir -p "$INSTALL_DIR/secrets"
    
    print_success "Directories created at $INSTALL_DIR"
}

download_files() {
    print_step "4/8" "Downloading configuration files..."
    
    cd "$INSTALL_DIR"
    
    # Download docker-compose.prod.yml
    print_status "Downloading docker-compose.yml..."
    if ! curl -fsSL "$COMPOSE_URL" -o docker-compose.yml; then
        print_error "Failed to download docker-compose.yml"
        exit 1
    fi
    
    # Download version.json for update tracking
    print_status "Downloading version.json..."
    if ! curl -fsSL "$VERSION_URL" -o version.json; then
        print_warning "Failed to download version.json (updates may not work correctly)"
    fi
    
    # Download guacamole init script
    print_status "Downloading Guacamole database init script..."
    if ! curl -fsSL "$GUAC_INITDB_URL" -o guacamole/initdb.sql; then
        print_error "Failed to download Guacamole init script"
        exit 1
    fi
    
    print_success "Configuration files downloaded"
}

copy_license() {
    print_step "5/8" "Installing license..."
    
    # SCRIPT_DIR was captured at script start, before any cd commands
    cp "$SCRIPT_DIR/license.lic" "$INSTALL_DIR/license.lic"
    chmod 600 "$INSTALL_DIR/license.lic"
    
    print_success "License installed"
}

configure_ssl() {
    print_status "Configuring SSL certificates..."
    
    mkdir -p "$INSTALL_DIR/nginx/ssl"
    
    if [[ -f "$INSTALL_DIR/nginx/ssl/nginx.crt" && -f "$INSTALL_DIR/nginx/ssl/nginx.key" ]]; then
        print_success "Existing SSL certificates found"
        return
    fi
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           SSL CERTIFICATE CONFIGURATION        ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════${NC}"
    echo ""
    echo "The SSL certificate will secure HTTPS access to Orkalab."
    echo ""
    
    # Prompt for external IP/domain
    read -p "External IP address or domain [$PRIMARY_IP]: " SSL_HOST_INPUT
    SSL_HOST=${SSL_HOST_INPUT:-$PRIMARY_IP}
    
    # Ask if there's also a domain name
    read -p "Do you have a domain name? [y/N]: " HAS_DOMAIN
    SSL_DOMAIN=""
    USE_LETSENCRYPT=false
    USE_CUSTOM_CERT=false
    
    if [[ "$HAS_DOMAIN" =~ ^[Yy]$ ]]; then
        read -p "Domain name (e.g., orkalab.example.com): " SSL_DOMAIN
        
        echo ""
        echo "SSL Certificate Options:"
        echo "  1) Use Let's Encrypt (free, automatic, recommended for public domains)"
        echo "  2) Use custom SSL certificates (for internal CA or existing certs)"
        echo "  3) Generate self-signed certificate (for testing only)"
        echo ""
        read -p "Choose SSL option [1-3]: " SSL_OPTION
        
        case "$SSL_OPTION" in
            1)
                USE_LETSENCRYPT=true
                echo ""
                echo -e "${CYAN}📋 Let's Encrypt Setup${NC}"
                echo ""
                echo "Let's Encrypt requires:"
                echo "  • Domain must point to this server's public IP"
                echo "  • Port 80 must be accessible from the internet"
                echo "  • Valid email address for renewal notifications"
                echo ""
                read -p "Email address for Let's Encrypt notifications: " LETSENCRYPT_EMAIL
                
                if [ -z "$LETSENCRYPT_EMAIL" ]; then
                    print_error "Email is required for Let's Encrypt"
                    USE_LETSENCRYPT=false
                    print_warning "Falling back to self-signed certificate"
                fi
                ;;
            2)
                USE_CUSTOM_CERT=true
                echo ""
                echo -e "${CYAN}📋 Custom SSL Certificate Setup${NC}"
                echo ""
                echo "You will need to provide your own SSL certificate files."
                echo "After installation, place your certificate files here:"
                echo "  • Certificate: $INSTALL_DIR/nginx/ssl/nginx.crt"
                echo "  • Private Key: $INSTALL_DIR/nginx/ssl/nginx.key"
                echo ""
                echo "Press Enter to continue with temporary self-signed certificate..."
                read
                ;;
            *)
                print_warning "Using self-signed certificate"
                ;;
        esac
    else
        echo ""
        echo "SSL Certificate Options:"
        echo "  1) Generate self-signed certificate (for testing)"
        echo "  2) I will provide my own certificates"
        echo ""
        read -p "Choose option [1-2]: " ssl_choice
        
        case $ssl_choice in
            2)
                USE_CUSTOM_CERT=true
                echo ""
                echo "Please copy your SSL certificates to:"
                echo "  - Certificate: $INSTALL_DIR/nginx/ssl/nginx.crt"
                echo "  - Private Key: $INSTALL_DIR/nginx/ssl/nginx.key"
                echo ""
                read -p "Press Enter when certificates are in place..."
                
                if [[ -f "$INSTALL_DIR/nginx/ssl/nginx.crt" && -f "$INSTALL_DIR/nginx/ssl/nginx.key" ]]; then
                    print_success "SSL certificates configured"
                    chmod 600 "$INSTALL_DIR/nginx/ssl/nginx.key"
                    return
                else
                    print_warning "Certificates not found, generating self-signed..."
                fi
                ;;
        esac
    fi
    
    # Let's Encrypt Certificate
    if [ "$USE_LETSENCRYPT" = true ] && [ -n "$SSL_DOMAIN" ] && [ -n "$LETSENCRYPT_EMAIL" ]; then
        print_status "Setting up Let's Encrypt certificate..."
        
        # Install certbot if not present
        if ! command -v certbot &> /dev/null; then
            print_status "Installing certbot..."
            apt-get update >> "$LOG_FILE" 2>&1
            if apt-get install -y certbot >> "$LOG_FILE" 2>&1; then
                print_success "Certbot installed"
            else
                print_error "Failed to install certbot"
                print_warning "Falling back to self-signed certificate"
                USE_LETSENCRYPT=false
            fi
        fi
        
        if [ "$USE_LETSENCRYPT" = true ]; then
            print_status "Obtaining Let's Encrypt certificate for $SSL_DOMAIN..."
            
            # Stop any running services on port 80
            docker compose -f "$INSTALL_DIR/docker-compose.yml" down 2>/dev/null || true
            
            # Use standalone mode
            if certbot certonly --standalone --non-interactive --agree-tos \
                --email "$LETSENCRYPT_EMAIL" \
                --domains "$SSL_DOMAIN" >> "$LOG_FILE" 2>&1; then
                
                # Copy certificates
                cp /etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem "$INSTALL_DIR/nginx/ssl/nginx.crt"
                cp /etc/letsencrypt/live/$SSL_DOMAIN/privkey.pem "$INSTALL_DIR/nginx/ssl/nginx.key"
                chmod 644 "$INSTALL_DIR/nginx/ssl/nginx.crt"
                chmod 600 "$INSTALL_DIR/nginx/ssl/nginx.key"
                
                print_success "Let's Encrypt certificate obtained"
                echo "  Domain: $SSL_DOMAIN"
                echo "  Auto-renewal: Enabled"
                
                # Set up auto-renewal cron job
                (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 2 * * * certbot renew --quiet --deploy-hook 'cp /etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem $INSTALL_DIR/nginx/ssl/nginx.crt && cp /etc/letsencrypt/live/$SSL_DOMAIN/privkey.pem $INSTALL_DIR/nginx/ssl/nginx.key && docker compose -f $INSTALL_DIR/docker-compose.yml restart nginx'") | crontab -
                
                return
            else
                print_error "Failed to obtain Let's Encrypt certificate"
                echo "Common issues:"
                echo "  • Domain doesn't point to this server"
                echo "  • Port 80 is blocked by firewall"
                print_warning "Falling back to self-signed certificate"
                USE_LETSENCRYPT=false
            fi
        fi
    fi
    
    # Generate self-signed certificate (default or fallback)
    print_status "Generating self-signed SSL certificate..."
    
    # Build alt_names section
    ALT_NAMES="DNS.1 = localhost"
    ALT_COUNTER=2
    
    if [ -n "$SSL_DOMAIN" ]; then
        ALT_NAMES="$ALT_NAMES
DNS.$ALT_COUNTER = $SSL_DOMAIN"
        ALT_COUNTER=$((ALT_COUNTER + 1))
        CN_VALUE="$SSL_DOMAIN"
    else
        CN_VALUE="${SSL_HOST:-orkalab.local}"
    fi
    
    ALT_NAMES="$ALT_NAMES
DNS.$ALT_COUNTER = orkalab.local
IP.1 = 127.0.0.1"
    
    # Add external IP if it's an IP address
    if [[ "$SSL_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ALT_NAMES="$ALT_NAMES
IP.2 = $SSL_HOST"
    fi
    
    # Add PRIMARY_IP if different
    if [ "$PRIMARY_IP" != "$SSL_HOST" ] && [ -n "$PRIMARY_IP" ]; then
        ALT_NAMES="$ALT_NAMES
IP.3 = $PRIMARY_IP"
    fi
    
    cat > /tmp/cert.conf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=US
ST=State
L=City
O=Orkalab
CN=$CN_VALUE

[v3_req]
subjectAltName = @alt_names

[alt_names]
$ALT_NAMES
EOF
    
    openssl req -new -x509 -nodes -days 365 \
        -keyout "$INSTALL_DIR/nginx/ssl/nginx.key" \
        -out "$INSTALL_DIR/nginx/ssl/nginx.crt" \
        -config /tmp/cert.conf -extensions v3_req 2>/dev/null
    
    rm -f /tmp/cert.conf
    chmod 600 "$INSTALL_DIR/nginx/ssl/nginx.key"
    
    print_success "Self-signed certificate generated"
    if [ "$USE_CUSTOM_CERT" = true ]; then
        print_warning "Replace with your custom certificate after installation"
    else
        print_warning "For production, use Let's Encrypt or valid certificates"
    fi
}

configure_proxmox() {
    print_status "Configuring Proxmox connection..."
    
    # Unset proxy for local network connections
    debug_log "Unsetting proxy for local network detection"
    export NO_PROXY="localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,*.local"
    export no_proxy="$NO_PROXY"
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    
    # Auto-detect Proxmox
    print_status "Auto-detecting Proxmox..."
    PROXMOX_DETECTED=""
    
    # Try localhost first
    for PORT in 8006 443; do
        debug_log "Testing https://127.0.0.1:${PORT}/api2/json/version"
        RESPONSE=$(curl -k -s -m 3 --noproxy "*" "https://127.0.0.1:${PORT}/api2/json/version" 2>/dev/null || true)
        if [ -n "$RESPONSE" ] && echo "$RESPONSE" | grep -q "version"; then
            PROXMOX_DETECTED="127.0.0.1:${PORT}"
            debug_log "✓ Found at 127.0.0.1:${PORT}"
            break
        fi
    done
    
    # Try primary IP
    if [ -z "$PROXMOX_DETECTED" ] && [ -n "$PRIMARY_IP" ]; then
        for PORT in 8006 443; do
            debug_log "Testing https://${PRIMARY_IP}:${PORT}/api2/json/version"
            RESPONSE=$(curl -k -s -m 3 --noproxy "*" "https://${PRIMARY_IP}:${PORT}/api2/json/version" 2>/dev/null || true)
            if [ -n "$RESPONSE" ] && echo "$RESPONSE" | grep -q "version"; then
                PROXMOX_DETECTED="${PRIMARY_IP}:${PORT}"
                debug_log "✓ Found at ${PRIMARY_IP}:${PORT}"
                break
            fi
        done
    fi
    
    if [ -n "$PROXMOX_DETECTED" ]; then
        print_success "Proxmox detected at $PROXMOX_DETECTED"
        PROXMOX_HOST="$PROXMOX_DETECTED"
    else
        print_warning "Could not auto-detect Proxmox"
        debug_log "Auto-detection failed - tried localhost, $PRIMARY_IP"
        PROXMOX_HOST="${PRIMARY_IP}:8006"
    fi
    
    echo ""
    echo -e "${YELLOW}Proxmox VE Configuration${NC}"
    echo "Enter your Proxmox server details:"
    echo ""
    
    read -p "Proxmox Host (IP:Port) [$PROXMOX_HOST]: " PROXMOX_INPUT
    PROXMOX_HOST=${PROXMOX_INPUT:-$PROXMOX_HOST}
    
    # Test connectivity
    print_status "Testing Proxmox connectivity..."
    debug_log "Testing https://${PROXMOX_HOST}/api2/json/version (no proxy)"
    PROXMOX_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" --noproxy "*" "https://${PROXMOX_HOST}/api2/json/version" 2>/dev/null || echo "000")
    debug_log "HTTP response code: $PROXMOX_TEST"
    
    if [ "$PROXMOX_TEST" = "200" ] || [ "$PROXMOX_TEST" = "401" ]; then
        print_success "Proxmox API reachable at ${PROXMOX_HOST}"
    else
        print_error "Cannot connect to Proxmox at ${PROXMOX_HOST} (HTTP ${PROXMOX_TEST})"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}API Token Authentication Required${NC}"
    echo "Format: user@realm!tokenid"
    echo "Example: root@pam!orkalab"
    echo ""
    
    PROXMOX_AUTH_SUCCESS=false
    PROXMOX_ATTEMPTS=0
    
    while [ "$PROXMOX_AUTH_SUCCESS" = false ] && [ $PROXMOX_ATTEMPTS -lt 3 ]; do
        PROXMOX_ATTEMPTS=$((PROXMOX_ATTEMPTS + 1))
        
        if [ $PROXMOX_ATTEMPTS -gt 1 ]; then
            print_error "Authentication failed. Attempt $PROXMOX_ATTEMPTS of 3"
        fi
        
        read -p "API Token ID (user@realm!tokenid): " PROXMOX_USER
        
        if [[ ! "$PROXMOX_USER" =~ ^[^@]+@[^!]+![^!]+$ ]]; then
            print_error "Invalid format. Must be: user@realm!tokenid"
            continue
        fi
        
        read -sp "API Token Secret: " PROXMOX_PASSWORD
        echo ""
        
        if [ -z "$PROXMOX_PASSWORD" ]; then
            print_error "Token secret cannot be empty"
            continue
        fi
        
        # Test authentication
        print_status "Testing API token authentication..."
        debug_log "Testing authentication with token: $PROXMOX_USER"
        NODES_RESPONSE=$(curl -k -s -w "\n%{http_code}" --noproxy "*" \
            -H "Authorization: PVEAPIToken=${PROXMOX_USER}=${PROXMOX_PASSWORD}" \
            "https://${PROXMOX_HOST}/api2/json/nodes" 2>/dev/null || true)
        
        HTTP_CODE=$(echo "$NODES_RESPONSE" | tail -1)
        RESPONSE_BODY=$(echo "$NODES_RESPONSE" | head -n -1)
        
        debug_log "Nodes API HTTP code: $HTTP_CODE"
        debug_log "Nodes API response: $RESPONSE_BODY"
        
        if [ "$HTTP_CODE" = "200" ] && echo "$RESPONSE_BODY" | grep -q '"data"'; then
            print_success "API token authenticated successfully"
            
            # Auto-detect node
            AVAILABLE_NODES=$(echo "$RESPONSE_BODY" | jq -r '.data[].node' 2>/dev/null || true)
            NODE_COUNT=$(echo "$AVAILABLE_NODES" | wc -l)
            
            debug_log "Available nodes: $AVAILABLE_NODES"
            debug_log "Node count: $NODE_COUNT"
            
            if [ -n "$AVAILABLE_NODES" ]; then
                if [ "$NODE_COUNT" = "1" ]; then
                    PROXMOX_NODE=$(echo "$AVAILABLE_NODES" | head -1)
                    print_success "Auto-detected node: $PROXMOX_NODE"
                else
                    print_success "Found $NODE_COUNT nodes:"
                    echo "$AVAILABLE_NODES" | nl -w2 -s'. '
                    read -p "Select node [1]: " NODE_CHOICE
                    NODE_CHOICE=${NODE_CHOICE:-1}
                    PROXMOX_NODE=$(echo "$AVAILABLE_NODES" | sed -n "${NODE_CHOICE}p")
                fi
            fi
            
            # Verify node access
            print_status "Verifying node access..."
            NODE_RESPONSE=$(curl -k -s -w "\n%{http_code}" --noproxy "*" \
                -H "Authorization: PVEAPIToken=${PROXMOX_USER}=${PROXMOX_PASSWORD}" \
                "https://${PROXMOX_HOST}/api2/json/nodes/${PROXMOX_NODE}/status" 2>/dev/null || true)
            
            NODE_HTTP_CODE=$(echo "$NODE_RESPONSE" | tail -1)
            debug_log "Node status HTTP code: $NODE_HTTP_CODE"
            
            if [ "$NODE_HTTP_CODE" = "200" ]; then
                print_success "Node '$PROXMOX_NODE' accessible"
            else
                print_warning "Cannot verify node '$PROXMOX_NODE' (HTTP $NODE_HTTP_CODE)"
            fi
            
            PROXMOX_AUTH_SUCCESS=true
        else
            print_error "Authentication failed (HTTP $HTTP_CODE)"
            debug_log "Full response: $RESPONSE_BODY"
        fi
    done
    
    if [ "$PROXMOX_AUTH_SUCCESS" = false ]; then
        print_error "Failed to authenticate with Proxmox after 3 attempts"
        exit 1
    fi
    
    PROXMOX_VERIFY_SSL="false"
    print_success "Proxmox configuration saved"
}

configure_sdn() {
    print_step "5/8" "Configuring Proxmox SDN Zone..."
    
    # CRITICAL: Enable FRRouting service (required for VXLAN SDN)
    print_status "Ensuring FRRouting service is enabled..."
    if ! systemctl is-active --quiet frr.service; then
        systemctl enable --now frr.service >> "$LOG_FILE" 2>&1
        print_success "FRRouting service started"
    else
        print_success "FRRouting already running"
    fi
    
    # Install dnsmasq (required for SDN DHCP/DNS functionality)
    print_status "Ensuring dnsmasq is installed..."
    if ! dpkg -l | grep -q "^ii  dnsmasq "; then
        # Stop systemd-resolved temporarily if running to avoid port 53 conflict
        if systemctl is-active --quiet systemd-resolved; then
            print_status "Stopping systemd-resolved temporarily to avoid port conflict..."
            systemctl stop systemd-resolved >> "$LOG_FILE" 2>&1
        fi
        
        # Install dnsmasq
        DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq >> "$LOG_FILE" 2>&1
        
        # Stop dnsmasq immediately after install (we'll configure it later)
        systemctl stop dnsmasq >> "$LOG_FILE" 2>&1 || true
        systemctl disable dnsmasq >> "$LOG_FILE" 2>&1 || true
        
        # Restart systemd-resolved if it was running
        if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
            systemctl start systemd-resolved >> "$LOG_FILE" 2>&1 || true
        fi
        
        print_success "dnsmasq installed (will be configured by SDN service)"
    else
        print_success "dnsmasq already installed"
    fi
    
    # Create NAT hook script for SDN networks
    # This ensures MASQUERADE/SNAT is always configured, even after network reloads
    print_status "Creating NAT hook script for SDN networks..."
    cat > /etc/network/if-up.d/orkalab-nat << 'NATHOOK'
#!/bin/sh
# OrkaLab NAT Hook Script
# Ensures SNAT/MASQUERADE is configured for SDN VXLAN networks
# This runs automatically on every network reload/reboot

# Only run on post-up phase
if [ "$PHASE" != "post-up" ]; then exit 0; fi

# Get the outbound interface (usually vmbr0)
OUTIF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$OUTIF" ]; then exit 0; fi

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

# Add MASQUERADE rule for all OrkaLab SDN networks (10.0.0.0/8)
# This covers ALL current and future sessions (10.1.0.0/24 through 10.250.0.0/24)
# The -C check prevents duplicate rules
iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -o $OUTIF -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o $OUTIF -j MASQUERADE

# Add FORWARD rules for SDN networks (CRITICAL: Required because default FORWARD policy is DROP)
iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
iptables -C FORWARD -d 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -j ACCEPT

logger "OrkaLab: Applied NAT and FORWARD rules for 10.0.0.0/8 via $OUTIF"
NATHOOK
    chmod +x /etc/network/if-up.d/orkalab-nat
    
    # Execute the hook now to ensure NAT is working immediately
    PHASE=post-up /etc/network/if-up.d/orkalab-nat 2>/dev/null || true
    
    # Force apply NAT rule immediately (CRITICAL FIX: Hook might not trigger if interface is already up)
    OUTIF=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ ! -z "$OUTIF" ]; then
        iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -o $OUTIF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o $OUTIF -j MASQUERADE
        
        # Force apply FORWARD rules immediately
        iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
        iptables -C FORWARD -d 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -j ACCEPT
    fi

    print_success "NAT hook script installed and executed"
    
    # SDN Configuration
    SDN_ZONE_NAME="orkalab"
    SDN_MTU="1400"
    
    # Check if SDN zone already exists
    print_status "Checking if SDN zone '${SDN_ZONE_NAME}' exists..."
    
    ZONE_CHECK=$(curl -k -s -w "\n%{http_code}" --noproxy "*" \
        -H "Authorization: PVEAPIToken=${PROXMOX_USER}=${PROXMOX_PASSWORD}" \
        "https://${PROXMOX_HOST}/api2/json/cluster/sdn/zones/${SDN_ZONE_NAME}" 2>/dev/null || true)
    
    ZONE_HTTP_CODE=$(echo "$ZONE_CHECK" | tail -1)
    
    if [ "$ZONE_HTTP_CODE" = "200" ]; then
        print_success "SDN zone '${SDN_ZONE_NAME}' already exists"
    else
        print_status "Creating SDN zone '${SDN_ZONE_NAME}' (VXLAN, MTU=${SDN_MTU})..."
        
        # Get the Proxmox host IP for VXLAN peers
        PROXMOX_IP=$(echo "$PROXMOX_HOST" | cut -d':' -f1)
        
        # Create VXLAN zone
        CREATE_RESULT=$(curl -k -s -w "\n%{http_code}" --noproxy "*" \
            -X POST \
            -H "Authorization: PVEAPIToken=${PROXMOX_USER}=${PROXMOX_PASSWORD}" \
            -d "zone=${SDN_ZONE_NAME}&type=vxlan&peers=${PROXMOX_IP}&mtu=${SDN_MTU}" \
            "https://${PROXMOX_HOST}/api2/json/cluster/sdn/zones" 2>/dev/null || true)
        
        CREATE_HTTP_CODE=$(echo "$CREATE_RESULT" | tail -1)
        CREATE_BODY=$(echo "$CREATE_RESULT" | head -n -1)
        
        if [ "$CREATE_HTTP_CODE" = "200" ] || echo "$CREATE_BODY" | grep -q "already exists"; then
            print_success "SDN zone '${SDN_ZONE_NAME}' created"
            
            # Apply SDN configuration
            print_status "Applying SDN configuration..."
            APPLY_RESULT=$(curl -k -s -w "\n%{http_code}" --noproxy "*" \
                -X PUT \
                -H "Authorization: PVEAPIToken=${PROXMOX_USER}=${PROXMOX_PASSWORD}" \
                "https://${PROXMOX_HOST}/api2/json/cluster/sdn" 2>/dev/null || true)
            
            APPLY_HTTP_CODE=$(echo "$APPLY_RESULT" | tail -1)
            
            if [ "$APPLY_HTTP_CODE" = "200" ]; then
                print_success "SDN configuration applied"
            else
                print_warning "Could not apply SDN config (may need manual apply in Proxmox UI)"
            fi
        else
            print_error "Failed to create SDN zone (HTTP $CREATE_HTTP_CODE)"
            print_warning "You may need to create it manually in Proxmox:"
            echo "   Datacenter → SDN → Zones → Add → VXLAN"
            echo "   - ID: ${SDN_ZONE_NAME}"
            echo "   - Peers: ${PROXMOX_IP}"
            echo "   - MTU: ${SDN_MTU}"
        fi
    fi
    
    # Pre-configure gateway IPs for all 250 potential subnets
    print_status "Pre-configuring gateway IPs for all 250 subnets..."
    echo "   This allows VMs to reach the gateway immediately without runtime configuration."
    
    GATEWAY_SUCCESS=0
    GATEWAY_SKIP=0
    for i in $(seq 1 250); do
        BRIDGE="s${i}"
        GATEWAY_IP="10.${i}.0.1/24"
        
        # Check if bridge exists (it won't until sessions are created, but configure if it does)
        if ip link show "$BRIDGE" &>/dev/null; then
            # Check if IP already configured
            if ip addr show "$BRIDGE" | grep -q "inet ${GATEWAY_IP%/*}/"; then
                GATEWAY_SKIP=$((GATEWAY_SKIP + 1))
            else
                # Add gateway IP to bridge
                if ip addr add "$GATEWAY_IP" dev "$BRIDGE" 2>/dev/null; then
                    ip link set "$BRIDGE" up 2>/dev/null
                    GATEWAY_SUCCESS=$((GATEWAY_SUCCESS + 1))
                fi
            fi
        fi
    done
    
    print_success "Gateway IP pre-configuration complete"
    echo "   Configured: ${GATEWAY_SUCCESS}, Already set: ${GATEWAY_SKIP}"
    echo "   Note: Remaining gateways will be configured when VNets are created"
    
    print_success "SDN configuration complete"
}

create_env_file() {
    print_step "6/8" "Creating environment configuration..."
    
    # Generate secure passwords (64-char hex matching install.sh)
    DB_PASSWORD=$(generate_password)
    JWT_SECRET=$(openssl rand -hex 64)
    GUAC_DB_PASSWORD=$(generate_password)
    
    # Guacamole admin credentials
    GUAC_ADMIN_USER="guacadmin"
    GUAC_ADMIN_PASSWORD="guacadmin"
    
    # VM credentials
    echo ""
    echo "VM Template Credentials (must match your Proxmox templates):"
    read -p "Linux VM username [root]: " VM_LINUX_USER_INPUT
    VM_LINUX_USERNAME=${VM_LINUX_USER_INPUT:-root}
    read -sp "Linux VM password (leave empty to auto-generate): " VM_LINUX_PASSWORD
    echo ""
    if [ -z "$VM_LINUX_PASSWORD" ]; then
        VM_LINUX_PASSWORD=$(openssl rand -hex 16)
        print_success "Linux VM password auto-generated: ${VM_LINUX_PASSWORD}"
        print_warning "IMPORTANT: Save this password for VM templates: ${VM_LINUX_PASSWORD}"
        sleep 2
    fi
    
    read -p "Windows VM username [Administrator]: " VM_WINDOWS_USER_INPUT
    VM_WINDOWS_USERNAME=${VM_WINDOWS_USER_INPUT:-Administrator}
    read -sp "Windows VM password (leave empty to auto-generate): " VM_WINDOWS_PASSWORD
    echo ""
    if [ -z "$VM_WINDOWS_PASSWORD" ]; then
        VM_WINDOWS_PASSWORD=$(openssl rand -hex 16)
        print_success "Windows VM password auto-generated: ${VM_WINDOWS_PASSWORD}"
        print_warning "IMPORTANT: Save this password for VM templates: ${VM_WINDOWS_PASSWORD}"
        sleep 2
    fi
    
    # AI Agent configuration
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  AI AGENT CONFIGURATION (OPTIONAL)"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Enable AI-powered assistance for sandbox and builder sessions?"
    echo "AI can help users with troubleshooting, installations, and command execution."
    echo ""
    read -p "Enable AI Agent? [y/N]: " ENABLE_AI
    
    AI_ENABLED="false"
    AI_PROVIDER="openai"
    OPENAI_API_KEY=""
    GEMINI_API_KEY=""
    AI_MODEL="gpt-4"
    AI_MAX_TOKENS="2000"
    AI_TEMPERATURE="0.7"
    
    if [[ "$ENABLE_AI" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Select AI provider:"
        echo "  1) OpenAI (GPT-4, GPT-3.5)"
        echo "  2) Google Gemini (Gemini Pro, Flash)"
        read -p "Provider choice [1]: " PROVIDER_CHOICE
        PROVIDER_CHOICE=${PROVIDER_CHOICE:-1}
        
        if [ "$PROVIDER_CHOICE" = "2" ]; then
            # Gemini configuration
            AI_PROVIDER="gemini"
            echo ""
            echo "Enter your Google Gemini API key (from https://makersuite.google.com/app/apikey):"
            read -sp "Gemini API Key: " GEMINI_API_KEY_INPUT
            echo ""
            
            if [ -n "$GEMINI_API_KEY_INPUT" ]; then
                print_status "Testing Gemini API key..."
                
                # Test the API key
                TEST_RESPONSE=$(curl -s -w "\n%{http_code}" \
                    "https://generativelanguage.googleapis.com/v1/models?key=$GEMINI_API_KEY_INPUT" 2>/dev/null)
                
                HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -n1)
                
                if [ "$HTTP_CODE" = "200" ]; then
                    AI_ENABLED="true"
                    GEMINI_API_KEY="$GEMINI_API_KEY_INPUT"
                    print_success "Gemini API key validated successfully"
                    
                    # Ask for model preference
                    echo ""
                    echo "Select Gemini model:"
                    echo "  1) gemini-pro (recommended, balanced)"
                    echo "  2) gemini-1.5-pro (most capable)"
                    echo "  3) gemini-1.5-flash (fastest, economical)"
                    echo "  4) gemini-2.0-flash-exp (experimental, latest)"
                    echo "  5) Custom model name"
                    read -p "Model choice [1]: " MODEL_CHOICE
                    MODEL_CHOICE=${MODEL_CHOICE:-1}
                    
                    case $MODEL_CHOICE in
                        2) AI_MODEL="gemini-1.5-pro" ;;
                        3) AI_MODEL="gemini-1.5-flash" ;;
                        4) AI_MODEL="gemini-2.0-flash-exp" ;;
                        5) 
                            read -p "Enter custom Gemini model name: " CUSTOM_MODEL
                            AI_MODEL="${CUSTOM_MODEL:-gemini-pro}"
                            ;;
                        *) AI_MODEL="gemini-pro" ;;
                    esac
                    
                    print_success "AI model set to: $AI_MODEL"
                    
                    # Test the model with a simple request
                    print_status "Testing model $AI_MODEL..."
                    TEST_MODEL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
                        -H "Content-Type: application/json" \
                        -d "{\"contents\":[{\"parts\":[{\"text\":\"Hello\"}]}]}" \
                        "https://generativelanguage.googleapis.com/v1/models/${AI_MODEL}:generateContent?key=$GEMINI_API_KEY_INPUT" 2>/dev/null)
                    
                    MODEL_HTTP_CODE=$(echo "$TEST_MODEL_RESPONSE" | tail -n1)
                    
                    if [ "$MODEL_HTTP_CODE" = "200" ]; then
                        print_success "Model $AI_MODEL is working correctly"
                    else
                        print_warning "Warning: Model test returned HTTP $MODEL_HTTP_CODE"
                        print_warning "Model may not exist or may not be available for your API key"
                        read -p "Continue anyway? [y/N]: " CONTINUE_CHOICE
                        if [[ ! "$CONTINUE_CHOICE" =~ ^[Yy]$ ]]; then
                            AI_ENABLED="false"
                            GEMINI_API_KEY=""
                            print_warning "AI disabled"
                        fi
                    fi
                else
                    print_error "Gemini API key validation failed (HTTP $HTTP_CODE)"
                    print_warning "AI will be disabled. You can enable it later in admin config."
                    AI_ENABLED="false"
                    GEMINI_API_KEY=""
                fi
            else
                print_warning "No API key provided. AI will be disabled."
            fi
        else
            # OpenAI configuration
            AI_PROVIDER="openai"
            echo ""
            echo "Enter your OpenAI API key (from https://platform.openai.com/api-keys):"
            read -sp "OpenAI API Key: " OPENAI_API_KEY_INPUT
            echo ""
            
            if [ -n "$OPENAI_API_KEY_INPUT" ]; then
                # Validate API key format
                if [[ "$OPENAI_API_KEY_INPUT" =~ ^sk-[a-zA-Z0-9]{48,}$ ]]; then
                    print_status "Testing OpenAI API key..."
                    
                    # Test the API key
                    TEST_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
                        -H "Authorization: Bearer $OPENAI_API_KEY_INPUT" \
                        -H "Content-Type: application/json" \
                        -d '{"model":"gpt-4","messages":[{"role":"user","content":"test"}],"max_tokens":5}' \
                        https://api.openai.com/v1/chat/completions 2>/dev/null)
                    
                    HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -n1)
                    
                    if [ "$HTTP_CODE" = "200" ]; then
                        AI_ENABLED="true"
                        OPENAI_API_KEY="$OPENAI_API_KEY_INPUT"
                        print_success "OpenAI API key validated successfully"
                        
                        # Ask for model preference
                        echo ""
                        echo "Select AI model:"
                        echo "  1) gpt-4 (recommended, more capable)"
                        echo "  2) gpt-4-turbo (faster, cheaper)"
                        echo "  3) gpt-3.5-turbo (fastest, most economical)"
                        echo "  4) gpt-4o (latest multimodal)"
                        echo "  5) Custom model name"
                        read -p "Model choice [1]: " MODEL_CHOICE
                        MODEL_CHOICE=${MODEL_CHOICE:-1}
                        
                        case $MODEL_CHOICE in
                            2) AI_MODEL="gpt-4-turbo" ;;
                            3) AI_MODEL="gpt-3.5-turbo" ;;
                            4) AI_MODEL="gpt-4o" ;;
                            5) 
                                read -p "Enter custom OpenAI model name: " CUSTOM_MODEL
                                AI_MODEL="${CUSTOM_MODEL:-gpt-4}"
                                ;;
                            *) AI_MODEL="gpt-4" ;;
                        esac
                        
                        print_success "AI model set to: $AI_MODEL"
                        
                        # Test the model
                        print_status "Testing model $AI_MODEL..."
                        TEST_MODEL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
                            -H "Authorization: Bearer $OPENAI_API_KEY_INPUT" \
                            -H "Content-Type: application/json" \
                            -d "{\"model\":\"$AI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"max_tokens\":5}" \
                            https://api.openai.com/v1/chat/completions 2>/dev/null)
                        
                        MODEL_HTTP_CODE=$(echo "$TEST_MODEL_RESPONSE" | tail -n1)
                        
                        if [ "$MODEL_HTTP_CODE" = "200" ]; then
                            print_success "Model $AI_MODEL is working correctly"
                        else
                            print_warning "Warning: Model test returned HTTP $MODEL_HTTP_CODE"
                            print_warning "Model may not exist or may not be available for your API key"
                            read -p "Continue anyway? [y/N]: " CONTINUE_CHOICE
                            if [[ ! "$CONTINUE_CHOICE" =~ ^[Yy]$ ]]; then
                                AI_ENABLED="false"
                                OPENAI_API_KEY=""
                                print_warning "AI disabled"
                            fi
                        fi
                    else
                        print_error "OpenAI API key validation failed (HTTP $HTTP_CODE)"
                        print_warning "AI will be disabled. You can enable it later in admin config."
                        AI_ENABLED="false"
                        OPENAI_API_KEY=""
                    fi
                else
                    print_error "Invalid API key format. Should start with 'sk-'"
                    print_warning "AI will be disabled. You can configure it later."
                    AI_ENABLED="false"
                    OPENAI_API_KEY=""
                fi
            else
                print_warning "No API key provided. AI will be disabled."
            fi
        fi
    else
        print_status "AI Agent disabled. Can be enabled later via admin configuration."
    fi
    
    cat > "$INSTALL_DIR/.env" << EOF
# ═══════════════════════════════════════════════════════════════════════════════
#  Orkalab Configuration (Commercial Edition)
#  Generated: $(date)
#  WARNING: This file contains sensitive information. Keep it secure!
# ═══════════════════════════════════════════════════════════════════════════════

# Database Configuration
DB_NAME=orkalab
DB_USER=orkalab
DB_PASSWORD=${DB_PASSWORD}

# Proxmox Configuration
PROXMOX_HOST=${PROXMOX_HOST}
PROXMOX_USER=${PROXMOX_USER}
PROXMOX_PASSWORD=${PROXMOX_PASSWORD}
PROXMOX_NODE=${PROXMOX_NODE}
PROXMOX_VERIFY_SSL=${PROXMOX_VERIFY_SSL}

# Network Configuration (SDN VXLAN)
SDN_ZONE_NAME=orkalab
SDN_MTU=1400
SDN_SUBNET_POOL_SIZE=250
SERVER_HOST=${PRIMARY_IP}

# Security
JWT_SECRET=${JWT_SECRET}

# Guacamole Configuration
GUAC_DB_PASSWORD=${GUAC_DB_PASSWORD}
GUAC_ADMIN_USER=${GUAC_ADMIN_USER}
GUAC_ADMIN_PASSWORD=${GUAC_ADMIN_PASSWORD}
GUACAMOLE_URL=http://guacamole:8080/guacamole
GUACAMOLE_ADMIN_USER=${GUAC_ADMIN_USER}
GUACAMOLE_ADMIN_PASSWORD=${GUAC_ADMIN_PASSWORD}

# VM Template Credentials
VM_LINUX_USERNAME=${VM_LINUX_USERNAME}
VM_LINUX_PASSWORD=${VM_LINUX_PASSWORD}
VM_WINDOWS_USERNAME=${VM_WINDOWS_USERNAME}
VM_WINDOWS_PASSWORD=${VM_WINDOWS_PASSWORD}

# DNS Configuration
PRIMARY_DNS=${DNS_PRIMARY:-8.8.8.8}
SECONDARY_DNS=${DNS_SECONDARY:-8.8.4.4}

# Docker Hub Configuration
DOCKER_HUB_USER=${DOCKER_HUB_USER}
VERSION=latest

# Docker Compose Project Name (DO NOT CHANGE)
COMPOSE_PROJECT_NAME=orkalab

# AI Agent Configuration
AI_ENABLED=${AI_ENABLED:-false}
AI_PROVIDER=${AI_PROVIDER:-openai}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
AI_MODEL=${AI_MODEL:-gpt-4}
AI_MAX_TOKENS=${AI_MAX_TOKENS:-2000}
AI_TEMPERATURE=${AI_TEMPERATURE:-0.7}

# Application Configuration
APP_NAME=Orkalab
ENVIRONMENT=production
LOG_LEVEL=INFO
EOF

    chmod 600 "$INSTALL_DIR/.env"
    
    # Create secrets files
    print_status "Creating Docker secrets..."
    echo -n "$DB_PASSWORD" > "$INSTALL_DIR/secrets/db_password.txt"
    echo -n "$GUAC_DB_PASSWORD" > "$INSTALL_DIR/secrets/guac_db_password.txt"
    echo -n "$JWT_SECRET" > "$INSTALL_DIR/secrets/jwt_secret.txt"
    echo -n "$PROXMOX_PASSWORD" > "$INSTALL_DIR/secrets/proxmox_password.txt"
    echo -n "$VM_LINUX_PASSWORD" > "$INSTALL_DIR/secrets/vm_linux_password.txt"
    echo -n "$VM_WINDOWS_PASSWORD" > "$INSTALL_DIR/secrets/vm_windows_password.txt"
    
    chmod 600 "$INSTALL_DIR/secrets"/*.txt
    
    print_success "Environment configuration created"
}

pull_and_start() {
    print_step "7/8" "Pulling images and starting services..."
    
    cd "$INSTALL_DIR"
    export COMPOSE_PROJECT_NAME=orkalab
    
    debug_log "Working directory: $(pwd)"
    debug_log "COMPOSE_PROJECT_NAME: $COMPOSE_PROJECT_NAME"
    
    # Check for existing volumes
    if docker volume ls | grep -q "orkalab_postgres_data"; then
        print_warning "Existing database volume detected"
        echo ""
        read -p "Remove old volumes and start fresh? (recommended) [Y/n]: " REMOVE_VOLUMES
        if [[ ! "$REMOVE_VOLUMES" =~ ^[Nn]$ ]]; then
            print_status "Removing old database volumes..."
            if [ "$DEBUG_MODE" = true ]; then
                docker compose down -v 2>&1 | tee -a "$LOG_FILE" || true
                docker volume rm orkalab_postgres_data orkalab_guac_data 2>&1 | tee -a "$LOG_FILE" || true
            else
                docker compose down -v >> "$LOG_FILE" 2>&1 || true
                docker volume rm orkalab_postgres_data orkalab_guac_data 2>> "$LOG_FILE" || true
            fi
            print_success "Old volumes removed - fresh start"
        fi
    fi
    
    # Pull images
    print_status "Pulling Docker images (this may take several minutes)..."
    if [ "$DEBUG_MODE" = true ]; then
        docker compose pull 2>&1 | tee -a "$LOG_FILE" || {
            print_error "Failed to pull Docker images"
            echo "Check your internet connection and Docker Hub access"
            exit 1
        }
    else
        docker compose pull >> "$LOG_FILE" 2>&1 || {
            print_error "Failed to pull Docker images"
            echo "Check your internet connection and Docker Hub access"
            exit 1
        }
    fi
    print_success "Docker images pulled"
    
    # Start services
    print_status "Starting services..."
    if [ "$DEBUG_MODE" = true ]; then
        docker compose up -d 2>&1 | tee -a "$LOG_FILE"
    else
        docker compose up -d >> "$LOG_FILE" 2>&1
    fi
    print_success "Containers started"
    
    # Wait for services to be healthy
    print_status "Waiting for services to initialize..."
    sleep 15
    
    # Check database is ready
    print_status "Waiting for database..."
    for i in {1..30}; do
        debug_log "Database check attempt $i/30"
        if docker compose exec -T postgres pg_isready -U orkalab >> "$LOG_FILE" 2>&1; then
            break
        fi
        sleep 2
    done
    print_success "Database ready"
    
    # Wait for backend to stabilize
    print_status "Waiting for backend container..."
    for i in {1..60}; do
        BACKEND_STATE=$(docker compose ps backend --format json 2>/dev/null | jq -r '.State' 2>/dev/null || echo "unknown")
        debug_log "Backend state attempt $i/60: $BACKEND_STATE"
        if [ "$BACKEND_STATE" = "running" ]; then
            sleep 5
            BACKEND_STATE_CHECK=$(docker compose ps backend --format json 2>/dev/null | jq -r '.State' 2>/dev/null || echo "unknown")
            if [ "$BACKEND_STATE_CHECK" = "running" ]; then
                print_success "Backend container is running"
                break
            fi
        fi
        if [ $i -eq 60 ]; then
            print_error "Backend container failed to stabilize"
            docker compose logs --tail=50 backend | tee -a "$LOG_FILE"
            exit 1
        fi
        sleep 2
    done
    
    # Run migrations
    print_status "Running database migrations..."
    MIGRATION_SUCCESS=false
    for attempt in {1..3}; do
        debug_log "Migration attempt $attempt/3"
        if [ "$DEBUG_MODE" = true ]; then
            if docker compose exec -T backend alembic upgrade head 2>&1 | tee -a "$LOG_FILE"; then
                MIGRATION_SUCCESS=true
                break
            fi
        else
            if docker compose exec -T backend alembic upgrade head >> "$LOG_FILE" 2>&1; then
                MIGRATION_SUCCESS=true
                break
            fi
        fi
        print_warning "Migration attempt $attempt failed, retrying..."
        sleep 10
    done
    
    if [ "$MIGRATION_SUCCESS" = true ]; then
        print_success "Database migrations completed"
    else
        print_error "Database migrations failed after 3 attempts"
        docker compose logs --tail=100 backend | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Admin user is created by database migration
    print_success "Admin user ready (username: admin, password: admin)"
    
    print_success "All services started successfully"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Management Script Installation
# ═══════════════════════════════════════════════════════════════════════════════

install_management_script() {
    print_step "8/8" "Installing management script..."
    
    cat > /usr/local/bin/orkalab << 'SCRIPT_EOF'
#!/bin/bash
# Orkalab Management Script

INSTALL_DIR="/opt/orkalab"
VERSION_URL="https://raw.githubusercontent.com/CursedScorpio/OrkaLab/main/version.json"

export COMPOSE_PROJECT_NAME=orkalab

cd "$INSTALL_DIR" || exit 1

case "$1" in
    start)
        docker compose up -d
        echo "Orkalab started"
        ;;
    stop)
        docker compose down
        echo "Orkalab stopped"
        ;;
    restart)
        docker compose restart
        echo "Orkalab restarted"
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f ${2:-}
        ;;
    update)
        echo "Checking for updates..."
        CURRENT=$(docker inspect cursedscropio/orkalab-backend:latest --format '{{.Id}}' 2>/dev/null || echo "none")
        docker compose pull
        NEW=$(docker inspect cursedscropio/orkalab-backend:latest --format '{{.Id}}' 2>/dev/null || echo "none")
        if [[ "$CURRENT" != "$NEW" ]]; then
            echo "New version available. Restarting services..."
            docker compose up -d
            echo "Update complete!"
        else
            echo "Already running the latest version."
        fi
        ;;
    check-update)
        echo "Current images:"
        docker compose images
        echo ""
        echo "Checking Docker Hub for updates..."
        docker compose pull --dry-run 2>&1 || echo "Use 'orkalab update' to pull new images"
        ;;
    version)
        echo "Orkalab Commercial Edition"
        echo "Installed at: $INSTALL_DIR"
        echo ""
        echo "Image versions:"
        docker compose images --format "table {{.Repository}}\t{{.Tag}}"
        ;;
    backup)
        BACKUP_DIR="${2:-/tmp/orkalab-backup-$(date +%Y%m%d-%H%M%S)}"
        mkdir -p "$BACKUP_DIR"
        echo "Backing up to $BACKUP_DIR..."
        docker compose exec -T postgres pg_dump -U orkalab orkalab > "$BACKUP_DIR/orkalab.sql"
        cp "$INSTALL_DIR/.env" "$BACKUP_DIR/.env"
        cp -r "$INSTALL_DIR/nginx/ssl" "$BACKUP_DIR/ssl"
        echo "Backup complete: $BACKUP_DIR"
        ;;
    *)
        echo "Orkalab Management"
        echo ""
        echo "Usage: orkalab <command>"
        echo ""
        echo "Commands:"
        echo "  start         Start all services"
        echo "  stop          Stop all services"
        echo "  restart       Restart all services"
        echo "  status        Show service status"
        echo "  logs [svc]    View logs (optionally for specific service)"
        echo "  update        Check and apply updates"
        echo "  check-update  Check for available updates"
        echo "  version       Show version information"
        echo "  backup [dir]  Backup database and config"
        echo ""
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/orkalab
    print_success "Management script installed: /usr/local/bin/orkalab"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Post-Installation
# ═══════════════════════════════════════════════════════════════════════════════

show_completion() {
    # Log completion
    echo "" >> "$LOG_FILE"
    echo "=== Installation Completed ===" >> "$LOG_FILE"
    echo "Finished: $(date)" >> "$LOG_FILE"
    echo "==============================" >> "$LOG_FILE"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}                                                                               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}              ${BOLD}🎉 Orkalab Installation Complete! 🎉${NC}                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                                               ${GREEN}║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}📋 Access URLs:${NC}"
    echo -e "  Frontend:    http://${PRIMARY_IP}"
    echo -e "               https://${PRIMARY_IP} (self-signed)"
    echo -e "  API Docs:    http://${PRIMARY_IP}/api/docs"
    echo -e "  Guacamole:   http://${PRIMARY_IP}/guacamole"
    echo ""
    echo -e "${CYAN}🔐 Default Admin Credentials:${NC}"
    echo -e "  ${BOLD}Username:${NC} admin"
    echo -e "  ${BOLD}Password:${NC} admin"
    echo -e "  ${YELLOW}⚠️  CHANGE PASSWORD AFTER FIRST LOGIN!${NC}"
    echo ""
    echo -e "${CYAN}🔐 Guacamole Admin:${NC}"
    echo -e "  ${BOLD}Username:${NC} guacadmin"
    echo -e "  ${BOLD}Password:${NC} guacadmin"
    echo ""
    echo -e "${CYAN}🌐 Network Configuration:${NC}"
    echo -e "  Bridge: $SELECTED_BRIDGE ($BRIDGE_IP)"
    echo -e "  Subnet: ${BRIDGE_SUBNET}.0/24"
    echo -e "  SDN Mode: VXLAN (VM isolation via Proxmox SDN)"
    echo -e "  DNS: $DNS_PRIMARY, $DNS_SECONDARY"
    echo ""
    echo -e "${CYAN}📄 Important Files:${NC}"
    echo -e "  • $INSTALL_DIR/.env (environment configuration)"
    echo -e "  • $INSTALL_DIR/nginx/ssl/nginx.crt (SSL certificate)"
    echo -e "  • $LOG_FILE (installation log)"
    echo ""
    echo -e "${CYAN}💡 Management Commands:${NC}"
    echo -e "  ${BOLD}orkalab status${NC}    - Check service status"
    echo -e "  ${BOLD}orkalab logs${NC}      - View logs"
    echo -e "  ${BOLD}orkalab restart${NC}   - Restart services"
    echo -e "  ${BOLD}orkalab update${NC}    - Update to latest version"
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT NEXT STEPS:${NC}"
    echo "   1. Login with admin/admin and CHANGE PASSWORD"
    echo "   2. Create VM templates in Proxmox with cloud-init enabled"
    echo "   3. Configure firewall if needed"
    echo "   4. Test by creating a scenario"
    echo ""
    echo -e "${CYAN}🌐 SDN Configuration:${NC} Automatically configured (zone: orkalab, VXLAN)"
    echo ""
    echo -e "${CYAN}Installation Directory:${NC} $INSTALL_DIR"
    echo ""
    echo -e "${BLUE}For support, contact your vendor or visit the documentation.${NC}"
    echo ""
    echo -e "${GREEN}Installation complete! Access your platform at http://${PRIMARY_IP}${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Main Installation Flow
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    # Setup logging with rotation
    mkdir -p "$(dirname "$LOG_FILE")"
    if [ -f "$LOG_FILE" ]; then
        # Rotate existing log file
        LOG_BACKUP="${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
        mv "$LOG_FILE" "$LOG_BACKUP"
        # Keep only last 5 backup logs
        ls -t ${LOG_FILE}.*.bak 2>/dev/null | tail -n +6 | xargs -r rm -f
        echo "Previous log rotated to: $LOG_BACKUP"
    fi
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo "=== Orkalab Commercial Installation Log ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    echo "Debug mode: $DEBUG_MODE" >> "$LOG_FILE"
    echo "============================================" >> "$LOG_FILE"
    
    # Enable debug mode if --debug flag was passed
    if [ "$DEBUG_MODE" = true ]; then
        set -x  # Enable bash debug mode (shows every command)
        echo -e "${MAGENTA}🐛 DEBUG MODE ENABLED (via --debug flag)${NC}"
        echo -e "${MAGENTA}   All commands will be logged to: $LOG_FILE${NC}"
        echo -e "${MAGENTA}   Tip: Run without --debug for normal installation${NC}"
        sleep 2
    fi
    
    # Disable enterprise repos before anything else
    disable_enterprise_repos
    
    print_banner
    
    print_section "Pre-Installation Checks"
    check_root
    check_os
    check_license
    check_network
    check_docker
    
    # System detection
    detect_system
    
    # Network configuration
    configure_network
    
    print_section "Installation"
    create_directories
    download_files
    copy_license
    configure_ssl
    configure_proxmox
    prompt_template_downloads
    configure_sdn
    create_env_file
    pull_and_start
    install_management_script
    
    show_completion
}

# Run installer
main "$@"
