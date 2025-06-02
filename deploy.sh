#!/bin/bash
## Multiple Repository Support Bash Script 

#######################################
# CONFIGURATION
#######################################
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="$HOME/logs/deployments.log"
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)_$$"
STATE_DIR="/var/tmp/deployment-states"
VERBOSE_LOG_DIR="$HOME/logs/deployments"
WEB_ROOT_MODIFIED=false

#######################################
# CORE FUNCTIONS
#######################################
log() {
   local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
   echo -e "[$timestamp] ${1}${2}${NC}"
}

handle_error() {
  log "$RED" "Error: $1"
  update_state "FAILED"
  
  if [ "$WEB_ROOT_MODIFIED" = true ] && [ -d "$BACKUP_DIR" ]; then
    log "$YELLOW" "Attempting to restore previous deployment..."
    rm -rf "${WEB_ROOT:?}/"*
    cp -r "$BACKUP_DIR"/* "$WEB_ROOT/" 2>/dev/null && log "$GREEN" "Previous deployment restored"
  fi
  
  exit 1
}

update_state() {
  echo "$1" > "$STATE_FILE"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  log "$BLUE" "State: $1"
}

cleanup_old_states() {
  find "$STATE_DIR" -name "deployment_${GITHUB_REPO_NAME}_*.state" -type f | sort -r | tail -n +11 | xargs -r rm -f
}

#######################################
# PM2 FUNCTIONS
#######################################
pm2_app_exists() {
    local app_name="$1"
    pm2 jlist 2>/dev/null | jq -e ".[] | select(.name == \"$app_name\")" >/dev/null 2>&1
}

pm2_get_status() {
    local app_name="$1"
    pm2 jlist 2>/dev/null | jq -r ".[] | select(.name == \"$app_name\") | .pm2_env.status" 2>/dev/null
}

pm2_ensure_running() {
    local app_name="$1"
    local start_command="$2"
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local status=$(pm2_get_status "$app_name")
        
        case "$status" in
            "online")
                log "$GREEN" "PM2 app '$app_name' is running"
                return 0
                ;;
            "stopped"|"stopping")
                log "$YELLOW" "PM2 app '$app_name' is stopped, starting..."
                pm2 start "$app_name" >/dev/null 2>&1
                ;;
            "errored")
                log "$YELLOW" "PM2 app '$app_name' has errored, deleting and restarting..."
                pm2 delete "$app_name" >/dev/null 2>&1
                status=""
                ;;
            *)
                if [ $attempt -eq 1 ]; then
                    log "$YELLOW" "Creating new PM2 app '$app_name'..."
                    pm2 start --name "$app_name" -- $start_command >/dev/null 2>&1
                fi
                ;;
        esac
        
        sleep 3
        ((attempt++))
    done
    
    [ "$(pm2_get_status "$app_name")" = "online" ]
}

#######################################
# UTILITY FUNCTIONS
#######################################
npm_script_exists() {
    local script_name="$1"
    [ -f "package.json" ] && jq -e ".scripts.\"$script_name\"" package.json >/dev/null 2>&1
}

backup_web_root() {
    if [ -d "$WEB_ROOT" ] && [ "$(ls -A "$WEB_ROOT" 2>/dev/null)" ]; then
        log "$YELLOW" "Backing up current deployment..."
        mkdir -p "$(dirname "$BACKUP_DIR")"
        chmod 700 "$(dirname "$BACKUP_DIR")" 2>/dev/null 
        cp -r "$WEB_ROOT" "$BACKUP_DIR" || log "$YELLOW" "Warning: Backup failed, continuing anyway"
        chmod -R 700 "$BACKUP_DIR" 2>/dev/null
    fi
}

validate_build_output() {
    local build_dir="$1"
    if [ ! -d "$build_dir" ]; then
        return 1
    fi

    [ "$(ls -A "$build_dir" 2>/dev/null)" ]
}

#######################################
# INITIALIZATION
#######################################
mkdir -p "$VERBOSE_LOG_DIR" 2>/dev/null
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR="/tmp"

chmod 700 "$VERBOSE_LOG_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

VERBOSE_LOG_FILE="$VERBOSE_LOG_DIR/${GITHUB_REPO_NAME}_${DEPLOYMENT_ID}.log"
STATE_FILE="$STATE_DIR/deployment_${GITHUB_REPO_NAME}_${DEPLOYMENT_ID}.state"
BACKUP_DIR="/var/tmp/deployment-backups/${GITHUB_REPO_NAME}_${DEPLOYMENT_ID}"

exec 3>&1 4>&2  
exec 1> >(tee -a "$VERBOSE_LOG_FILE")
exec 2>&1

update_state "STARTING"

for tool in git npm jq; do
  command -v "$tool" >/dev/null 2>&1 || handle_error "$tool is not installed"
done

[ -z "$GITHUB_REPO_NAME" ] && handle_error "GITHUB_REPO_NAME is not set"
[ -z "$GITHUB_BRANCH" ] && handle_error "GITHUB_BRANCH is not set"
[ -z "$GITHUB_REPO_OWNER" ] && handle_error "GITHUB_REPO_OWNER is not set"
[ -z "$GITHUB_PUSHER" ] && handle_error "GITHUB_PUSHER is not set"
[ -z "$GITHUB_COMMIT" ] && handle_error "GITHUB_COMMIT is not set" 
[ -z "$GITHUB_REPO_FULL_NAME" ] && handle_error "GITHUB_REPO_FULL_NAME is not set"

#######################################
# REPOSITORY CONFIGURATION
#######################################
case "$GITHUB_REPO_NAME" in
    "zoneyhub")
        REPO_DIR="/home/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"
        WEB_ROOT="/var/www/html/${GITHUB_REPO_NAME}"
        FULL_STACK=false
        PROJECT_TYPE="CLIENT" 
        CLIENT_DIR="client"
        SERVER_DIR="server"
        SERVER_ENTRY="app.js"
        ;;
    "URL-Shortener-App")
        REPO_DIR="/home/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"
        WEB_ROOT="/var/www/html/${GITHUB_REPO_NAME}"
        PROJECT_TYPE="API_JS" 
        FULL_STACK=false
        CLIENT_DIR="client"
        SERVER_DIR="server"
        SERVER_ENTRY="app.js"
        ;;
    "MEDHUB")
        REPO_DIR="/home/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"
        WEB_ROOT="/var/www/html/${GITHUB_REPO_NAME}"
        PROJECT_TYPE="API_TS" 
        FULL_STACK=false
        CLIENT_DIR="client"
        SERVER_DIR="server" 
        SERVER_ENTRY="app.js"
        ;;
    *)
        REPO_DIR="/home/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}"
        WEB_ROOT="/var/www/html/${GITHUB_REPO_NAME}"
        PROJECT_TYPE="CLIENT" 
        FULL_STACK=false
        CLIENT_DIR="client"
        SERVER_DIR="server" 
        SERVER_ENTRY="app.js"
        ;;
esac

[ -z "$REPO_DIR" ] || [[ "$REPO_DIR" =~ \.\. ]] && handle_error "Invalid REPO_DIR path"
[ -z "$WEB_ROOT" ] || [[ "$WEB_ROOT" =~ \.\. ]] && handle_error "Invalid WEB_ROOT path"

log "$YELLOW" "Starting deployment process..."
log "$BLUE" "Repository: ${GITHUB_REPO_NAME}"
log "$BLUE" "Type: ${PROJECT_TYPE} | Fullstack: ${FULL_STACK}"
log "$BLUE" "Deployment ID: ${DEPLOYMENT_ID}"

if [ "$PROJECT_TYPE" != "CLIENT" ]; then
  command -v pm2 >/dev/null 2>&1 || handle_error "PM2 is not installed but required for $PROJECT_TYPE"
fi

#######################################
# GIT OPERATIONS
#######################################
log "$YELLOW" "Navigating to repository directory..."
cd "$REPO_DIR" || handle_error "Failed to change directory to $REPO_DIR"

REPO_ROOT=$(pwd)

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    log "$YELLOW" "Warning: Uncommitted changes detected. Stashing..."
    STASH_NAME="deployment-auto-stash-${DEPLOYMENT_ID}"
    git stash push -m "$STASH_NAME" || handle_error "Failed to stash changes"
    STASHED=true
else
    STASHED=false
fi

update_state "FETCHING"
log "$YELLOW" "Fetching latest changes from GitHub..."
git fetch || handle_error "Failed to fetch from GitHub"

LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse "origin/$GITHUB_BRANCH")

if [ "$LOCAL" = "$REMOTE" ]; then
    log "$GREEN" "No changes to deploy. Your site is up to date!"

    if [ "$STASHED" = true ]; then
        log "$YELLOW" "Restoring stashed changes..."
        git stash pop || log "$YELLOW" "Warning: Failed to restore stashed changes"
    fi
    cleanup_old_states
    exit 0
fi

update_state "PULLING"
log "$YELLOW" "Pulling latest changes from GitHub..."
git pull origin "$GITHUB_BRANCH" || {
    if [ "$STASHED" = true ]; then
        log "$YELLOW" "Pull failed. Attempting to restore stash and retry..."
        git stash pop || true
        STASHED=false
    fi
    handle_error "Failed to pull from GitHub - possible merge conflict"
}

if [ "$STASHED" = true ]; then
    log "$YELLOW" "Restoring stashed changes..."
    git stash pop || log "$YELLOW" "Warning: Failed to restore stashed changes"
fi

#######################################
# DEPLOYMENT LOGIC
#######################################
 # Backend deployment
if [ "$FULL_STACK" = false ] && [ "$PROJECT_TYPE" != "CLIENT" ]; then
    update_state "DEPLOYING_SERVER"
    
    log "$YELLOW" "Deploying server API..."

    if [ ! -d "$REPO_ROOT/$SERVER_DIR" ]; then
        handle_error "Server directory '$SERVER_DIR' does not exist in repository"
    fi
    
    cd "$REPO_ROOT/$SERVER_DIR" || handle_error "Failed to change directory to server"
    
    [ -f "package.json" ] || handle_error "No package.json found in server directory"
    
    log "$YELLOW" "Installing dependencies..."
    npm ci --prefer-offline --no-audit || npm install || handle_error "Failed to install dependencies"
    
    # for JS (No build needed)
    if [ "$PROJECT_TYPE" = "API_JS" ]; then
        if pm2_app_exists "${GITHUB_REPO_NAME}"; then
            log "$YELLOW" "Restarting existing PM2 app..."
            pm2 restart "${GITHUB_REPO_NAME}" >/dev/null 2>&1
        fi
        
        pm2_ensure_running "${GITHUB_REPO_NAME}" "${SERVER_ENTRY}" || handle_error "Failed to start PM2 app"

    # for TS (build needed)  
    elif [ "$PROJECT_TYPE" = "API_TS" ]; then
        if ! npm_script_exists "build"; then
            handle_error "No 'build' script found in package.json"
        fi
        
        log "$YELLOW" "Building TypeScript application..."
        npm run build || handle_error "Failed to run typescript build"

        if [ -d "dist" ]; then
          SERVER_BUILD_OUTPUT="dist"
        elif [ -d "build" ]; then
          SERVER_BUILD_OUTPUT="build"
        else
          handle_error "No server build output found (dist/build missing)"
        fi
        
        validate_build_output "$SERVER_BUILD_OUTPUT" || handle_error "Build output directory is empty"

        if pm2_app_exists "${GITHUB_REPO_NAME}"; then
            log "$YELLOW" "Restarting existing PM2 app..."
            pm2 restart "${GITHUB_REPO_NAME}" >/dev/null 2>&1
        fi
        
        pm2_ensure_running "${GITHUB_REPO_NAME}" "$SERVER_BUILD_OUTPUT/${SERVER_ENTRY}" || handle_error "Failed to start PM2 app"
    fi

    pm2 save || log "$YELLOW" "Warning: Failed to save PM2 configuration"

# Frontend deployment
elif [ "$FULL_STACK" = false ] && [ "$PROJECT_TYPE" = "CLIENT" ]; then
    update_state "DEPLOYING_CLIENT"

    log "$YELLOW" "Deploying client app..."

    if [ -n "$CLIENT_DIR" ] && [ "$CLIENT_DIR" != "." ]; then
        if [ ! -d "$REPO_ROOT/$CLIENT_DIR" ]; then
            handle_error "Client directory '$CLIENT_DIR' does not exist in repository"
        fi
        
        log "$YELLOW" "Navigating to client directory: $CLIENT_DIR"
        cd "$REPO_ROOT/$CLIENT_DIR" || handle_error "Failed to change directory to $CLIENT_DIR"
    fi

    [ -f "package.json" ] || handle_error "No package.json found in client directory"

    log "$YELLOW" "Installing dependencies..."
    npm ci --prefer-offline --no-audit || npm install || handle_error "Failed to install dependencies"
    
    if ! npm_script_exists "build"; then
        handle_error "No 'build' script found in package.json"
    fi
    
    log "$YELLOW" "Building the application..."
    npm run build || handle_error "Failed to build application"

    if [ -d "dist" ]; then
      CLIENT_BUILD_OUTPUT="dist"
    elif [ -d "build" ]; then
      CLIENT_BUILD_OUTPUT="build"
    else
      handle_error "No client build output found (dist/build missing)"
    fi
    
    validate_build_output "$CLIENT_BUILD_OUTPUT" || handle_error "Build output directory is empty"
    
    log "$YELLOW" "Deploying to web root..."

    if [ -z "$WEB_ROOT" ] || [ "$WEB_ROOT" = "/" ] || [ "$WEB_ROOT" = "/home" ]; then
        handle_error "Refusing to delete: WEB_ROOT is set to a dangerous value: '$WEB_ROOT'"
    fi

    backup_web_root

    log "$YELLOW" "Clearing web root at: $WEB_ROOT"
    WEB_ROOT_MODIFIED=true
    rm -rf "${WEB_ROOT:?}/"* || handle_error "Failed to clear web root"

    cp -r "$CLIENT_BUILD_OUTPUT"/* "$WEB_ROOT/" || handle_error "Failed to copy files to web root"
    
    log "$YELLOW" "Restarting Nginx..."
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>/dev/null; then
            systemctl --user start nginx-restart.service 2>/dev/null || \
            systemctl restart nginx 2>/dev/null || \
            service nginx restart 2>/dev/null || \
            log "$YELLOW" "Warning: Could not restart Nginx automatically"
        else
            log "$RED" "Nginx configuration test failed - not restarting"
        fi
    else
        log "$YELLOW" "Nginx not found - skipping restart"
    fi

# Fullstack deployment
elif [ "$FULL_STACK" = true ]; then
    update_state "DEPLOYING_FULLSTACK"

    log "$YELLOW" "Deploying Fullstack project..."
    
    log "$YELLOW" "Step 1/2: Deploying server API..."
    
    if [ ! -d "$REPO_ROOT/$SERVER_DIR" ]; then
        handle_error "Server directory '$SERVER_DIR' does not exist in repository"
    fi
    
    cd "$REPO_ROOT/$SERVER_DIR" || handle_error "Failed to change directory to server"
    
    [ -f "package.json" ] || handle_error "No package.json found in server directory"
    
    log "$YELLOW" "Installing server dependencies..."
    npm ci --prefer-offline --no-audit || npm install || handle_error "Failed to install server dependencies"
    
    # For JS (No build needed)
    if [ "$PROJECT_TYPE" = "API_JS" ] || [ "$PROJECT_TYPE" = "CLIENT" ]; then
        if pm2_app_exists "${GITHUB_REPO_NAME}"; then
            log "$YELLOW" "Restarting existing PM2 app..."
            pm2 restart "${GITHUB_REPO_NAME}" >/dev/null 2>&1
        fi
        
        pm2_ensure_running "${GITHUB_REPO_NAME}" "${SERVER_ENTRY}" || handle_error "Failed to start PM2 app"

    # For TS (build needed)  
    elif [ "$PROJECT_TYPE" = "API_TS" ]; then
        if ! npm_script_exists "build"; then
            handle_error "No 'build' script found in package.json"
        fi
        
        log "$YELLOW" "Building TypeScript server..."
        npm run build || handle_error "Failed to run typescript build"
        
        if [ -d "dist" ]; then
          SERVER_BUILD_OUTPUT="dist"
        elif [ -d "build" ]; then
          SERVER_BUILD_OUTPUT="build"
        else
          handle_error "No server build output found (dist/build missing)"
        fi
        
        validate_build_output "$SERVER_BUILD_OUTPUT" || handle_error "Server build output directory is empty"

        if pm2_app_exists "${GITHUB_REPO_NAME}"; then
            log "$YELLOW" "Restarting existing PM2 app..."
            pm2 restart "${GITHUB_REPO_NAME}" >/dev/null 2>&1
        fi
        
        pm2_ensure_running "${GITHUB_REPO_NAME}" "$SERVER_BUILD_OUTPUT/${SERVER_ENTRY}" || handle_error "Failed to start PM2 app"
    fi

    pm2 save || log "$YELLOW" "Warning: Failed to save PM2 configuration"

    log "$YELLOW" "Step 2/2: Deploying Client App..."

    if [ -n "$CLIENT_DIR" ] && [ "$CLIENT_DIR" != "." ]; then
      if [ ! -d "$REPO_ROOT/$CLIENT_DIR" ]; then
          handle_error "Client directory '$CLIENT_DIR' does not exist in repository"
      fi
      
      log "$YELLOW" "Navigating to client directory: $CLIENT_DIR"
      cd "$REPO_ROOT/$CLIENT_DIR" || handle_error "Failed to change directory to $CLIENT_DIR"
    fi
    
    [ -f "package.json" ] || handle_error "No package.json found in client directory"
    
    log "$YELLOW" "Installing client dependencies..."
    npm ci --prefer-offline --no-audit || npm install || handle_error "Failed to install client dependencies"
    
    if ! npm_script_exists "build"; then
        handle_error "No 'build' script found in package.json"
    fi
    
    log "$YELLOW" "Building the client application..."
    npm run build || handle_error "Failed to build client application"
    
    if [ -d "dist" ]; then
      CLIENT_BUILD_OUTPUT="dist"
    elif [ -d "build" ]; then
      CLIENT_BUILD_OUTPUT="build"
    else
      handle_error "No client build output found (dist/build missing)"
    fi
    
    validate_build_output "$CLIENT_BUILD_OUTPUT" || handle_error "Client build output directory is empty"
    
    log "$YELLOW" "Deploying to web root..."   

    if [ -z "$WEB_ROOT" ] || [ "$WEB_ROOT" = "/" ] || [ "$WEB_ROOT" = "/home" ]; then
        handle_error "Refusing to delete: WEB_ROOT is set to a dangerous value: '$WEB_ROOT'"
    fi

    backup_web_root

    log "$YELLOW" "Clearing web root at: $WEB_ROOT"
    WEB_ROOT_MODIFIED=true
    rm -rf "${WEB_ROOT:?}/"* || handle_error "Failed to clear web root"

    cp -r "$CLIENT_BUILD_OUTPUT"/* "$WEB_ROOT/" || handle_error "Failed to copy files to web root"
    
    log "$YELLOW" "Restarting Nginx..."
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>/dev/null; then
            systemctl --user start nginx-restart.service 2>/dev/null || \
            systemctl restart nginx 2>/dev/null || \
            service nginx restart 2>/dev/null || \
            log "$YELLOW" "Warning: Could not restart Nginx automatically"
        else
            log "$RED" "Nginx configuration test failed - not restarting"
        fi
    else
        log "$YELLOW" "Nginx not found - skipping restart"
    fi

else
    handle_error "Invalid deployment configuration: PROJECT_TYPE=$PROJECT_TYPE, FULL_STACK=$FULL_STACK"
fi

#######################################
# FINALIZATION
#######################################
if [ ! -z "$SLACK_WEBHOOK_URL" ]; then
    curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"✅ Deployed ${GITHUB_REPO_NAME} (${GITHUB_COMMIT:0:7}) to ${GITHUB_BRANCH} by ${GITHUB_PUSHER}\"}" \
        "$SLACK_WEBHOOK_URL" 2>/dev/null
fi

update_state "SUCCESS"

if [ -d "$(dirname "$BACKUP_DIR")" ]; then
    find "$(dirname "$BACKUP_DIR")" -maxdepth 1 -name "${GITHUB_REPO_NAME}_*" -type d | sort -r | tail -n +6 | xargs -r rm -rf
fi

cleanup_old_states

log "$GREEN" "Deployment completed successfully!"
log "$GREEN" "Deployed ${GITHUB_REPO_NAME} (${GITHUB_COMMIT:0:7}) to ${GITHUB_BRANCH} branch"
log "$BLUE" "Deployment ID: ${DEPLOYMENT_ID}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
chmod 700 "$(dirname "$LOG_FILE")" 2>/dev/null

if [ -w "$(dirname "$LOG_FILE")" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${DEPLOYMENT_ID} | ${GITHUB_PUSHER} | ${GITHUB_REPO_FULL_NAME}:${GITHUB_BRANCH} | ${GITHUB_COMMIT:0:7}" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null
    find "$VERBOSE_LOG_DIR" -name "${GITHUB_REPO_NAME}_*.log" -type f | sort -r | tail -n +21 | xargs -r rm -f
else
    log "$YELLOW" "Warning: Cannot write to log file $LOG_FILE"
fi