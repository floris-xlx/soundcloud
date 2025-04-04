#!/bin/bash

# Get script directory (where .xbp/xbp.json lives if no CLI args)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBP_JSON="$SCRIPT_DIR/xbp.json"

# Default to empty
APP_NAME=""
PORT=""
APP_DIR=""

# Parse CLI args
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --app-name)
            APP_NAME="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --app-dir)
            APP_DIR="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# If missing arguments, fallback to JSON
if [[ -z "$APP_NAME" || -z "$PORT" || -z "$APP_DIR" ]]; then
    if [ ! -f "$XBP_JSON" ]; then
        echo "Missing CLI arguments and no $XBP_JSON found."
        exit 1
    fi

    echo "Reading deploy config from $XBP_JSON..."
    APP_NAME=$(jq -r '.project_name' "$XBP_JSON")
    PORT=$(jq -r '.port' "$XBP_JSON")
    APP_DIR=$(jq -r '.build_dir' "$XBP_JSON")
fi

# Validate values
if [[ -z "$APP_NAME" || -z "$PORT" || -z "$APP_DIR" ]]; then
    echo "Error: Missing required deployment parameters."
    exit 1
fi

APP_DIR=$(realpath "$APP_DIR")
XBP_JSON="$APP_DIR/.xbp/xbp.json"

if [ ! -f "$XBP_JSON" ]; then
    echo "Expected JSON at $XBP_JSON not found."
    exit 1
fi

# Ensure jq is available
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is not installed."
    exit 1
fi

# Check port availability
if sudo fuser "${PORT}/tcp" > /dev/null 2>&1; then
    echo "Port $PORT is in use. Attempting to kill process..."
    if sudo fuser -k "${PORT}/tcp"; then
        echo "Successfully killed process on port $PORT."
    else
        echo "Failed to kill process on port $PORT. Searching for a new one..."
        for ((NEW_PORT=1025; NEW_PORT<=65535; NEW_PORT++)); do
            if ! sudo fuser "${NEW_PORT}/tcp" > /dev/null 2>&1; then
                PORT=$NEW_PORT
                echo "Found free port: $PORT"
                break
            fi
        done
        if [[ "$PORT" -gt 65535 ]]; then
            echo "No free ports available."
            exit 1
        fi
        # Update .xbp/xbp.json
        jq ".port = $PORT" "$XBP_JSON" > "$XBP_JSON.tmp" && mv "$XBP_JSON.tmp" "$XBP_JSON"
    fi
fi

# Deploy
echo "Deploying $APP_NAME on port $PORT"

cd "$APP_DIR" || { echo "Failed to cd into $APP_DIR"; exit 1; }

echo "Resetting repo..."
git reset --hard || { echo "Git reset failed"; exit 1; }

echo "Pulling latest changes..."
git pull origin main || { echo "Git pull failed"; exit 1; }

echo "Installing dependencies..."
pnpm install || { echo "Install failed"; exit 1; }

echo "Building project..."
pnpm run build || { echo "Build failed"; exit 1; }

echo "Stopping old PM2 process..."
pm2 stop "$APP_NAME" || echo "No existing PM2 process."

echo "Killing any process on port $PORT..."
sudo fuser -k ${PORT}/tcp || echo "Nothing on port $PORT."

echo "Starting PM2 process..."
pm2 start "pnpm run start -p $PORT" --name "$APP_NAME" -- --port $PORT || { echo "Failed to start app"; exit 1; }

echo "Saving PM2 process list..."
pm2 save || { echo "PM2 save failed"; exit 1; }

echo "✅ Deployed $APP_NAME on port $PORT"
