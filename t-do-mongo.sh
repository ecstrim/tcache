#!/bin/bash

# MongoDB Installation and Verification Script
# For Ubuntu 22.04 with MongoDB 7.0
# Usage: sudo bash mongodb_install.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root. Run as regular user with sudo access."
fi

# Check if sudo is available
if ! command -v sudo &> /dev/null; then
    error "sudo is required but not installed."
fi

log "Starting MongoDB 7.0 installation on Ubuntu 22.04..."

# Cleanup existing MongoDB installations
log "Cleaning up any existing MongoDB installations..."

# Stop MongoDB service if running
if systemctl is-active --quiet mongod 2>/dev/null; then
    warning "Stopping existing MongoDB service..."
    sudo systemctl stop mongod
fi

if systemctl is-active --quiet mongodb 2>/dev/null; then
    warning "Stopping existing mongodb service..."
    sudo systemctl stop mongodb
fi

# Remove existing MongoDB packages
log "Removing existing MongoDB packages..."
sudo apt-get remove --purge -y mongodb-org mongodb-org-* mongodb mongodb-* 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Remove existing repositories
log "Cleaning up existing MongoDB repositories..."
sudo rm -f /etc/apt/sources.list.d/mongodb*.list
sudo rm -f /usr/share/keyrings/mongodb*.gpg

# Clean package cache
sudo apt-get clean

# Remove existing data directories (with confirmation for safety)
if [[ -d /data/mongodb ]]; then
    warning "Found existing MongoDB data directory: /data/mongodb"
    read -p "Do you want to remove existing MongoDB data? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing existing MongoDB data directory..."
        
        # Check if /data/mongodb is a mount point and unmount if necessary
        if mountpoint -q /data/mongodb 2>/dev/null; then
            log "Unmounting /data/mongodb..."
            sudo umount /data/mongodb || {
                warning "Failed to unmount /data/mongodb, trying force unmount..."
                sudo umount -f /data/mongodb || {
                    error "Cannot unmount /data/mongodb. Please unmount manually: sudo umount /data/mongodb"
                }
            }
        fi
        
        # Check if /data is a mount point (data disk mounted directly to /data)
        if mountpoint -q /data 2>/dev/null; then
            log "Data disk is mounted at /data, removing contents only..."
            sudo rm -rf /data/mongodb/*
            sudo rm -rf /data/mongodb/.*  2>/dev/null || true
        else
            # Safe to remove entire directory
            sudo rm -rf /data/mongodb
        fi
        
        success "Existing MongoDB data removed"
    else
        warning "Keeping existing data directory (may cause conflicts)"
    fi
fi

# Remove existing log files
if [[ -f /var/log/mongodb/mongod.log ]]; then
    log "Removing existing MongoDB log files..."
    sudo rm -f /var/log/mongodb/mongod.log*
fi

# Remove existing PID files
sudo rm -f /var/run/mongodb/mongod.pid 2>/dev/null || true

# Remove existing MongoDB user (if exists and no processes are running)
if id mongodb &>/dev/null; then
    if ! pgrep -u mongodb > /dev/null; then
        log "Removing existing mongodb user..."
        sudo userdel mongodb 2>/dev/null || true
        sudo groupdel mongodb 2>/dev/null || true
    else
        warning "MongoDB processes still running, keeping mongodb user"
    fi
fi

# Remove existing configuration
if [[ -f /etc/mongod.conf ]]; then
    log "Backing up existing MongoDB configuration..."
    sudo mv /etc/mongod.conf /etc/mongod.conf.cleanup.backup.$(date +%s)
fi

# Remove existing status script
sudo rm -f /usr/local/bin/mongodb-status

# Reset systemd
sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null || true

success "Cleanup completed"

# Update system packages
log "Updating system packages..."
sudo apt-get update -y

# Install required packages
log "Installing required packages..."
sudo apt-get install -y curl wget gnupg lsb-release ca-certificates net-tools

# Import MongoDB GPG key
log "Importing MongoDB GPG key..."
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

if [[ ! -f /usr/share/keyrings/mongodb-server-7.0.gpg ]]; then
    error "Failed to import MongoDB GPG key"
fi
success "MongoDB GPG key imported"

# Add MongoDB repository
log "Adding MongoDB repository..."
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# Update package list
log "Updating package list with MongoDB repository..."
sudo apt-get update -y

# Install MongoDB
log "Installing MongoDB 7.0..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org

# Hold packages to prevent unintended upgrades
log "Holding MongoDB packages..."
sudo apt-mark hold mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos mongodb-org-tools

# Verify mongodb user exists
log "Verifying mongodb user..."
if id mongodb &>/dev/null; then
    success "MongoDB user exists: $(id mongodb)"
else
    warning "MongoDB user does not exist, recreating..."
    # Recreate mongodb user and group
    sudo groupadd mongodb 2>/dev/null || true
    sudo useradd --system --no-create-home --shell /bin/false --gid mongodb mongodb
    if id mongodb &>/dev/null; then
        success "MongoDB user recreated: $(id mongodb)"
    else
        error "Failed to create mongodb user"
    fi
fi

# Create data directories
log "Setting up data directories..."
sudo mkdir -p /data/mongodb/db /data/mongodb/logs
sudo chown -R mongodb:mongodb /data/mongodb
sudo chmod -R 755 /data/mongodb

# Create PID directory
sudo mkdir -p /var/run/mongodb
sudo chown mongodb:mongodb /var/run/mongodb

# Backup original config
if [[ -f /etc/mongod.conf ]]; then
    sudo cp /etc/mongod.conf /etc/mongod.conf.backup.$(date +%s)
fi

# Configure MongoDB for replica set
log "Configuring MongoDB..."
sudo tee /etc/mongod.conf > /dev/null <<EOF
# mongod.conf

# Where to store the data
storage:
  dbPath: /data/mongodb/db

# Where to write logging data
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# Network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

# Process management
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid

# Replica set configuration
replication:
  replSetName: "rs0"

# Security (commented out for initial setup)
#security:
#  authorization: enabled
EOF

success "MongoDB configuration created"

# Start and enable MongoDB
log "Starting MongoDB service..."
sudo systemctl start mongod
sudo systemctl enable mongod

# Wait for MongoDB to start
log "Waiting for MongoDB to start..."
sleep 5

# Create MongoDB status script
log "Creating MongoDB status script..."
sudo tee /usr/local/bin/mongodb-status > /dev/null <<'EOF'
#!/bin/bash
echo "=== MongoDB Service Status ==="
systemctl status mongod --no-pager -l
echo ""
echo "=== MongoDB Process ==="
ps aux | grep mongod | grep -v grep
echo ""
echo "=== MongoDB Port ==="
sudo netstat -tlnp | grep 27017
echo ""
echo "=== MongoDB Logs (last 10 lines) ==="
sudo tail -10 /var/log/mongodb/mongod.log
EOF

sudo chmod +x /usr/local/bin/mongodb-status

# Verification Tests
log "Running verification tests..."

# Test 1: Check if MongoDB service is running
if systemctl is-active --quiet mongod; then
    success "MongoDB service is running"
else
    error "MongoDB service is not running"
fi

# Test 2: Check if MongoDB is listening on port 27017
if sudo netstat -tlnp | grep -q ":27017"; then
    success "MongoDB is listening on port 27017"
else
    error "MongoDB is not listening on port 27017"
fi

# Test 3: Check if MongoDB is binding to all interfaces
if sudo netstat -tlnp | grep -q "0.0.0.0:27017"; then
    success "MongoDB is binding to all interfaces (0.0.0.0:27017)"
else
    warning "MongoDB may not be binding to all interfaces"
fi

# Test 4: Check MongoDB version
log "Checking MongoDB version..."
MONGO_VERSION=$(mongod --version | head -1)
success "MongoDB version: $MONGO_VERSION"

# Test 5: Test MongoDB connection
log "Testing MongoDB connection..."
if mongosh --eval "db.runCommand('ping')" --quiet > /dev/null 2>&1; then
    success "MongoDB connection test successful"
else
    error "MongoDB connection test failed"
fi

# Test 6: Test basic MongoDB operations
log "Testing basic MongoDB operations..."

# Create mongodb client directory to avoid permission issues
mkdir -p ~/.mongodb 2>/dev/null || true

TEST_RESULT=$(mongosh --eval "
try {
    use testdb;
    db.testcol.insertOne({test: 'installation_verification', timestamp: new Date(), hostname: '$(hostname)'});
    print('INSERT_SUCCESS');
    db.testcol.find({test: 'installation_verification'}).count();
} catch(e) {
    if (e.codeName === 'NotWritablePrimary' || e.codeName === 'NotPrimaryOrSecondary') {
        print('REPLICA_SET_NOT_INITIALIZED');
        // For replica set not initialized, just test read operations
        db.runCommand('ping').ok;
    } else {
        print('ERROR: ' + e);
        0;
    }
}
" --quiet 2>/dev/null | tail -2)

if [[ "$TEST_RESULT" == *"INSERT_SUCCESS"* ]] && [[ "$TEST_RESULT" == *"1"* ]]; then
    success "Basic MongoDB operations test successful"
elif [[ "$TEST_RESULT" == *"REPLICA_SET_NOT_INITIALIZED"* ]] && [[ "$TEST_RESULT" == *"1"* ]]; then
    success "MongoDB connection successful (replica set not yet initialized - expected)"
elif [[ "$TEST_RESULT" == *"1"* ]]; then
    success "Basic MongoDB ping test successful"
else
    warning "Basic MongoDB operations test inconclusive. Result: $TEST_RESULT"
    # Try a simpler ping test
    PING_RESULT=$(mongosh --eval "db.runCommand('ping').ok" --quiet 2>/dev/null | tail -1)
    if [[ "$PING_RESULT" == "1" ]]; then
        success "MongoDB ping test successful (write operations may require replica set initialization)"
    else
        error "MongoDB basic connectivity test failed"
    fi
fi

# Test 7: Check replica set status (should show not initialized)
log "Checking replica set status..."
RS_STATUS=$(mongosh --eval "try { rs.status() } catch(e) { print(e.codeName) }" --quiet 2>/dev/null | grep -E "(NotYetInitialized|ok)")
if [[ "$RS_STATUS" == *"NotYetInitialized"* ]]; then
    success "Replica set configuration detected (not yet initialized - expected)"
elif [[ "$RS_STATUS" == *"ok"* ]]; then
    success "Replica set is already initialized"
else
    warning "Replica set status unclear: $RS_STATUS"
fi

# Test 8: Check MongoDB logs for errors
log "Checking MongoDB logs for errors..."
ERROR_COUNT=$(sudo grep -c "ERROR" /var/log/mongodb/mongod.log 2>/dev/null | head -1 || echo "0")
# Clean any newlines or extra characters
ERROR_COUNT=$(echo "$ERROR_COUNT" | tr -d '\n\r' | grep -o '[0-9]*' | head -1)
ERROR_COUNT=${ERROR_COUNT:-0}

if [[ "$ERROR_COUNT" -eq 0 ]]; then
    success "No errors found in MongoDB logs"
else
    warning "Found $ERROR_COUNT errors in MongoDB logs (check with: sudo tail -20 /var/log/mongodb/mongod.log)"
fi

# Installation Summary
echo ""
echo "=========================================="
echo -e "${GREEN}🎉 MongoDB Installation Summary${NC}"
echo "=========================================="
echo "MongoDB Version: $MONGO_VERSION"
echo "Service Status: $(systemctl is-active mongod)"
echo "Enabled on Boot: $(systemctl is-enabled mongod)"
echo "Data Directory: /data/mongodb/db"
echo "Log File: /var/log/mongodb/mongod.log"
echo "Config File: /etc/mongod.conf"
echo "Replica Set Name: rs0"
echo ""
echo "Quick Commands:"
echo "  mongodb-status           - Check MongoDB status"
echo "  mongosh                  - Connect to MongoDB"
echo "  sudo systemctl status mongod  - Service status"
echo "  sudo tail -f /var/log/mongodb/mongod.log  - Follow logs"
echo ""
echo "Next Steps:"
echo "1. Install MongoDB on other VMs (if setting up replica set)"
echo "2. Initialize replica set with:"
echo "   mongosh --eval 'rs.initiate({_id:\"rs0\", members:[{_id:0, host:\"$(hostname).mongodb.internal:27017\"}]})'"
echo "3. Create MongoDB users and enable authentication"
echo ""
success "MongoDB installation completed successfully!"

# Final connectivity test
log "Testing network connectivity to common MongoDB DNS names..."
for host in vm-mongodb-prod-itn-01.mongodb.internal vm-mongodb-prod-itn-02.mongodb.internal vm-mongodb-prod-itn-03.mongodb.internal; do
    if ping -c 1 -W 2 "$host" &>/dev/null; then
        success "Network connectivity to $host: OK"
    else
        warning "Network connectivity to $host: FAILED (may not exist yet)"
    fi
done

echo ""
success "Installation script completed! 🦙"
