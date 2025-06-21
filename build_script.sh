#!/bin/bash

# build_script.sh

# Exit immediately if a command exits with a non-zero status.
set -e
# Optional: print each command before it's executed (for debugging)
# set -x

# --- Configuration ---
# Get the directory where the script is located, so it can be run from anywhere
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Firefox source repository URL (as per your previous request)
FIREFOX_SOURCE_URL="https://github.com/mozilla-firefox/firefox.git"
# Directory where Firefox source will be cloned (relative to SCRIPT_DIR)
FIREFOX_SOURCE_SUBDIR="firefox-source"
FIREFOX_SOURCE_DIR="$SCRIPT_DIR/$FIREFOX_SOURCE_SUBDIR"

# Your patches repository URL
PATCHES_REPO_URL="https://github.com/Sprunglesonthehub/Patches.git"
# Directory where your patches repo will be cloned (relative to SCRIPT_DIR)
PATCHES_REPO_SUBDIR="Patches-repo"
PATCHES_REPO_DIR="$SCRIPT_DIR/$PATCHES_REPO_SUBDIR"
# Subdirectory within PATCHES_REPO_DIR containing .patch files
PATCHES_SUBDIR_IN_REPO="patches" # This is Patches-repo/patches/

# Default branch to checkout from Firefox source.
# IMPORTANT: Verify this branch exists in the mozilla-firefox/firefox repo
# and corresponds to the version you want to build (e.g., 'master', 'main', or a release tag/branch)
DEFAULT_FIREFOX_BRANCH="master"

# Name of your mozconfig file (expected to be in SCRIPT_DIR)
MOZCONFIG_FILE_NAME="custom.mozconfig"

# Name for the build object directory (will be created one level above FIREFOX_SOURCE_DIR)
BUILD_ARTIFACTS_DIR_NAME="obj-firefox-Sprung"
BUILD_ARTIFACTS_DIR="$SCRIPT_DIR/$BUILD_ARTIFACTS_DIR_NAME" # Full path

# --- Functions ---

# Function to check if a command exists
ensure_command_exists() {
    command -v "$1" >/dev/null 2>&1 || {
        echo >&2 "Error: Command '$1' not found. Please install it and ensure it's in your PATH."
        exit 1
    }
}

# Function to fetch/update a Git repository
fetch_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local repo_name # Will be derived from target_dir
    repo_name=$(basename "$target_dir")
    local default_branch_arg="$3" # Optional: specific branch to use

    echo ">>> Managing repository: $repo_name"
    if [ ! -d "$target_dir/.git" ]; then
        echo "Cloning $repo_name from $repo_url..."
        # Using a shallow clone for Firefox source can save a lot of time and space initially
        # Remove --depth 1 if you need full history for specific tag checkouts not at the tip
        if [ "$repo_name" == "$(basename "$FIREFOX_SOURCE_DIR")" ]; then
             git clone --depth 1 --branch "$default_branch_arg" "$repo_url" "$target_dir"
        else
            git clone "$repo_url" "$target_dir" # Full clone for patches repo
        fi
    else
        echo "Updating $repo_name in $target_dir..."
        cd "$target_dir"
        git fetch origin --prune # --prune removes remote-tracking branches that no longer exist on remote
        git checkout . # Discard local changes to tracked files
        git clean -fdx # Remove untracked files and directories, including those from .gitignore
    fi


    # Determine the branch to checkout/reset to
    local branch_to_use
    if [ -n "$default_branch_arg" ]; then
        branch_to_use="$default_branch_arg"
    else
        # Try to find the default branch if not specified (for patches repo)
        cd "$target_dir" # Ensure we are in the repo dir
        branch_to_use=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
        if [ -z "$branch_to_use" ]; then
            echo "Warning: Could not determine default branch for $repo_name. Using 'master'."
            branch_to_use="master" # Fallback
        fi
        cd "$SCRIPT_DIR" # Go back to script dir
    fi

    echo "Checking out and resetting $repo_name to origin/$branch_to_use..."
    cd "$target_dir"
    git checkout "$branch_to_use"
    git reset --hard "origin/$branch_to_use"
    git clean -fdx # Extra clean after reset
    cd "$SCRIPT_DIR"
}

# Function to apply patches
apply_patches_from_repo() {
    local patches_source_dir="$1" # Full path to where .patch files are (e.g., PATCHES_REPO_DIR/PATCHES_SUBDIR_IN_REPO)
    local firefox_target_dir="$2" # Full path to FIREFOX_SOURCE_DIR

    echo ">>> Applying patches from $patches_source_dir to $firefox_target_dir"

    if [ ! -d "$patches_source_dir" ]; then
        echo "Error: Patches directory '$patches_source_dir' not found."
        exit 1
    fi

    cd "$firefox_target_dir"
    echo "Current directory for patching: $(pwd)"

    echo "Cleaning Firefox source directory before applying patches..."
    # Ensure we are on the correct branch before cleaning.
    # The fetch_repo function should have already set this up.
    local current_branch_ff
    current_branch_ff=$(git symbolic-ref --short HEAD || git rev-parse HEAD)
    echo "Firefox source is on branch/commit: $current_branch_ff"
    # Re-assert clean state just in case.
    git reset --hard "origin/$DEFAULT_FIREFOX_BRANCH" # Or whatever branch it's supposed to be on
    git clean -fdx

    # Apply patches in lexicographical order (e.g., 0001-*, 0002-*)
    # Using find and sort to get patch files
    find "$patches_source_dir" -type f -name "*.patch" | sort | while IFS= read -r patch_file; do
        echo "Applying $(basename "$patch_file")..."
        # Use git apply. --binary for binary patches (like search.json.mozlz4)
        # --check first to see if it applies cleanly
        if git apply --check --verbose --binary "$patch_file"; then
            git apply --verbose --binary "$patch_file"
        else
            echo "ERROR: Patch check failed for $(basename "$patch_file")."
            echo "Attempting to apply with --reject to see conflicts..."
            if git apply --reject --verbose --binary "$patch_file"; then
                echo "Patch $(basename "$patch_file") applied with .rej files. Please inspect conflicts in $firefox_target_dir."
                echo "Build process will be halted due to patch conflicts."
            else
                echo "FATAL: Could not even apply patch $(basename "$patch_file") with --reject."
            fi
            exit 1 # Halt on any patch failure
        fi
    done
    echo ">>> All patches applied successfully."
    cd "$SCRIPT_DIR"
}

# Function to build Firefox
build_firefox_custom() {
    local firefox_build_dir="$1" # Full path to FIREFOX_SOURCE_DIR
    local mozconfig_path_in_script_dir="$2" # Full path to custom.mozconfig
    local objdir_path="$3" # Full path to BUILD_ARTIFACTS_DIR

    echo ">>> Building Custom Firefox from $firefox_build_dir"
    cd "$firefox_build_dir"

    # Ensure .mozconfig uses the specified objdir
    if [ -f "$mozconfig_path_in_script_dir" ]; then
        echo "Copying $mozconfig_path_in_script_dir to $firefox_build_dir/.mozconfig"
        cp "$mozconfig_path_in_script_dir" .mozconfig

        # Ensure MOZ_OBJDIR is set correctly in the .mozconfig
        # This makes sure build artifacts go outside the source tree.
        if ! grep -q "mk_add_options MOZ_OBJDIR=" .mozconfig; then
            echo "Adding MOZ_OBJDIR to .mozconfig..."
            # Note: The path to MOZ_OBJDIR in .mozconfig needs to be relative to TOPSRCDIR
            # or an absolute path. TOPSRCDIR is the root of firefox_build_dir.
            # So, if objdir_path is $SCRIPT_DIR/obj-firefox-Sprung
            # and firefox_build_dir is $SCRIPT_DIR/firefox-source
            # the relative path from TOPSRCDIR is ../obj-firefox-Sprung
            local relative_objdir_path="../$(basename "$objdir_path")"
            echo "mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/$relative_objdir_path" >> .mozconfig
            echo "MOZ_OBJDIR set to: $relative_objdir_path (relative to source root)"
        else
            echo "MOZ_OBJDIR seems to be already set in .mozconfig. Verifying..."
            # This is a simple check; a more robust one would parse the actual path.
            grep "mk_add_options MOZ_OBJDIR=" .mozconfig
        fi
    else
        echo "Error: $mozconfig_path_in_script_dir not found."
        echo "Please create it with your build configurations."
        exit 1
    fi

    # Bootstrap Firefox build environment
    # For macOS, typically --no-system-changes if dependencies are already installed via Homebrew.
    # The --application-choice is important for non-interactive setup.
    echo "Running mach bootstrap..."
    if [[ "$(uname)" == "Darwin" ]]; then
        ./mach bootstrap --no-system-changes --application-choice "Firefox for Desktop"
    elif [[ "$(uname)" == "Linux" ]]; then
        # On Linux, bootstrap might need to install system packages if not present.
        # Running non-interactively might require specific flags or pre-installed deps.
        # For a fully automated script, ensure all deps are met beforehand.
        ./mach bootstrap --application-choice "Firefox for Desktop"
    else
        echo "Unsupported OS for automated bootstrap in this script: $(uname)"
        exit 1
    fi
    echo "Bootstrap complete."

    echo "Running mach build..."
    ./mach build -j$(sysctl -n hw.ncpu) # Use all available CPU cores for building

    echo ">>> Build complete."
    echo "To run your custom Firefox: cd $firefox_build_dir && ./mach run"
    echo "Packaged application (if any) will be in $objdir_path/dist/"
    echo "To package manually: cd $firefox_build_dir && ./mach package"
    cd "$SCRIPT_DIR"
}

# --- Main Script Execution ---

echo "Starting Firefox Fork Build Process..."
echo "Script directory: $SCRIPT_DIR"
echo "Firefox source will be in: $FIREFOX_SOURCE_DIR"
echo "Patches repository will be in: $PATCHES_REPO_DIR"
echo "Build artifacts will be in: $BUILD_ARTIFACTS_DIR"

# 0. Check for necessary commands
ensure_command_exists "git"
ensure_command_exists "find"
ensure_command_exists "sort"
ensure_command_exists "grep"
ensure_command_exists "basename"
ensure_command_exists "uname"
ensure_command_exists "sysctl" # For macOS to get CPU cores, use nproc on Linux

# 1. Fetch/Update Firefox Source Code
fetch_repo "$FIREFOX_SOURCE_URL" "$FIREFOX_SOURCE_DIR" "$DEFAULT_FIREFOX_BRANCH"

# 2. Fetch/Update Your Patches Repository
# For patches repo, we typically want its default branch (master/main determined by git remote show origin)
fetch_repo "$PATCHES_REPO_URL" "$PATCHES_REPO_DIR" # No specific branch, uses remote's default

# 3. Apply Patches
# The patches are located in a subdirectory of the patches repo
apply_patches_from_repo "$PATCHES_REPO_DIR/$PATCHES_SUBDIR_IN_REPO" "$FIREFOX_SOURCE_DIR"

# 4. Build Custom Firefox
build_firefox_custom "$FIREFOX_SOURCE_DIR" "$SCRIPT_DIR/$MOZCONFIG_FILE_NAME" "$BUILD_ARTIFACTS_DIR"

echo ">>> Firefox Fork build process finished successfully!"
echo "Find your built browser components in $BUILD_ARTIFACTS_DIR"
echo "If packaged, the .app/.dmg will be in $BUILD_ARTIFACTS_DIR/dist/"
