#!/bin/bash

# SimVirtualLocation Build Script
# Usage: ./build.sh [command]
# Commands: build, run, clean, rebuild, debug

set -e

PROJECT="SimVirtualLocation.xcodeproj"
SCHEME="SimVirtualLocation"
BUILD_DIR="./build"
APP_PATH="$BUILD_DIR/Build/Products/Debug/SimVirtualLocation.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

function build_app() {
    print_header "🔨 Building $SCHEME..."

    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E "BUILD|error|warning|note:" || true

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}✅ Build succeeded${NC}"
        echo -e "${GREEN}📦 App location: $APP_PATH${NC}"
        return 0
    else
        echo -e "${RED}❌ Build failed${NC}"
        return 1
    fi
}

function run_app() {
    if [ ! -d "$APP_PATH" ]; then
        echo -e "${YELLOW}⚠️  App not found. Building first...${NC}"
        build_app || exit 1
    fi

    print_header "🚀 Launching SimVirtualLocation..."
    open "$APP_PATH"

    echo -e "${GREEN}✅ App launched${NC}"
    echo -e "${YELLOW}💡 Tip: View logs in the app's bottom panel or run: ./build.sh debug${NC}"
}

function clean_build() {
    print_header "🧹 Cleaning build directory..."

    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        echo -e "${GREEN}✅ Build directory cleaned${NC}"
    else
        echo -e "${YELLOW}ℹ️  Build directory doesn't exist${NC}"
    fi
}

function rebuild_app() {
    # Kill running instances first
    if pgrep -f "SimVirtualLocation.app" > /dev/null; then
        echo -e "${YELLOW}🛑 Closing running app...${NC}"
        pkill -f "SimVirtualLocation.app"
        sleep 0.5
    fi

    clean_build
    build_app
}

function show_logs() {
    print_header "📋 Showing live logs (Press Ctrl+C to stop)..."
    echo -e "${YELLOW}Waiting for SimVirtualLocation to start...${NC}\n"

    log stream --predicate 'process == "SimVirtualLocation"' --level debug --style compact
}

function check_pymobiledevice3() {
    print_header "🔍 Checking pymobiledevice3 installation..."

    PATHS=(
        "/opt/homebrew/bin/pymobiledevice3"
        "/usr/local/bin/pymobiledevice3"
        "$HOME/.local/bin/pymobiledevice3"
    )

    FOUND=false
    for path in "${PATHS[@]}"; do
        if [ -f "$path" ]; then
            echo -e "${GREEN}✅ Found: $path${NC}"
            $path --version 2>&1 | head -1
            FOUND=true
            break
        fi
    done

    if [ "$FOUND" = false ]; then
        # Check ~/Library/Python/*/bin/
        echo -e "${YELLOW}Searching in ~/Library/Python/...${NC}"
        LIBRARY_PATHS=$(find "$HOME/Library/Python" -name "pymobiledevice3" 2>/dev/null || true)

        if [ -n "$LIBRARY_PATHS" ]; then
            echo -e "${GREEN}✅ Found in Library:${NC}"
            echo "$LIBRARY_PATHS"
        else
            echo -e "${RED}❌ pymobiledevice3 not found${NC}"
            echo -e "${YELLOW}Install with:${NC}"
            echo "brew install python3 && python3 -m pip install -U pymobiledevice3 --break-system-packages --user"
        fi
    fi
}

function show_help() {
    cat << EOF
${BLUE}SimVirtualLocation Build Script${NC}

Usage: ./build.sh [command]

Commands:
    ${GREEN}build${NC}       Build the app only
    ${GREEN}run${NC}         Run the app (builds if needed)
    ${GREEN}clean${NC}       Clean build directory
    ${GREEN}rebuild${NC}     Clean, rebuild, and run (default)
    ${GREEN}debug${NC}       Show live logs
    ${GREEN}check${NC}       Check pymobiledevice3 installation
    ${GREEN}help${NC}        Show this help message

Examples:
    ./build.sh              # Clean rebuild and run (default)
    ./build.sh build        # Just build
    ./build.sh run          # Just run existing build
    ./build.sh rebuild      # Clean rebuild and run
    ./build.sh debug        # View live logs

Tips:
    - Use Xcode (⌘R) for debugging with breakpoints
    - Check app's bottom panel for execution logs
    - Run './build.sh check' to verify pymobiledevice3 setup

EOF
}

# Main script logic
case "${1:-rebuild}" in
    build)
        build_app
        ;;
    run)
        run_app
        ;;
    clean)
        clean_build
        ;;
    rebuild)
        rebuild_app
        run_app
        ;;
    debug)
        show_logs
        ;;
    check)
        check_pymobiledevice3
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${YELLOW}Unknown command: $1${NC}"
        echo "Run './build.sh help' for usage information"
        exit 1
        ;;
esac
