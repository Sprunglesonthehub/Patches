#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for debugging - prints each command before it's executed

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )" # Root dir of this script
# --- MODIFIED: Firefox Source URL ---
FIREFOX_SOURCE_URL="https://github.com/mozilla-firefox/firefox.git"
# --- End MODIFIED ---
FIREFOX_SOURCE_DIR="$SCRIPT_DIR/firefox-source"   # Where Firefox source will be cloned
PATCHES_REPO_URL="https://github.com/Sprunglesonthehub/Patches.git"
PATCHES_REPO_DIR="$SCRIPT_DIR/Patches-repo"      # Where your patches repo will be cloned
PATCHES_SUBDIR="patches"                         # Subdirectory within PATCHES_REPO_DIR containing .patch files
DEFAULT_FIREFOX_BRANCH="master"                  # Default branch to checkout from Firefox source. Adjust if needed.

# --- Functions ---

ensure_command_exists() {
    command -v "$1" >/dev/null 2>&1 || { echo >&2 "Error: Command '$1' not found. Please install it."; exit 1; }
}

fetch_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local repo_name=$(basename "$target_dir")
    local default_branch_arg="$3" # Optional: specific branch to use

    echo ">>> Managing repository: $repo_name"
    if [ ! -d "$target_dir/.git" ]; then
        echo "Cloning $repo_name from $repo_url..."
        # Consider --depth 1 if you only need the latest and the repo is huge.
        # However, for patch development and potential version targeting, a full clone might be better eventually.
        git clone "$repo_url" "$target_dir"
    fi

    echo "Updating $repo_name in $target_dir..."
    cd "$target_dir"
    git fetch origin --prune # --prune removes remote-tracking branches that no longer exist on remote

    # Determine the branch to checkout/reset to
    local branch_to_use
    if [ -n "$default_branch_arg" ]; then
        branch_to_use="$default_branch_arg"
    else
        # Try to find the default branch if not specified
        branch_to_use=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
        if [ -z "$branch_to_use" ]; then
            echo "Warning: Could not determine default branch for $repo_name. Using 'master'."
            branch_to_use="master" # Fallback, adjust if your repo uses 'main' or something else
        fi
    fi

    echo "Resetting $repo_name to origin/$branch_to_use..."
    git checkout "$branch_to_use" # Checkout the branch first
    git reset --hard "origin/$branch_to_use"
    git clean -fdx # Remove untracked files and directories
    cd "$SCRIPT_DIR"

}

apply_patches_from_repo() {
    echo ">>> Applying patches from $PATCHES_REPO_DIR/$PATCHES_SUBDIR to $FIREFOX_SOURCE_DIR"

    if [ ! -d "$PATCHES_REPO_DIR/$PATCHES_SUBDIR" ]; then
        echo "Error: Patches directory '$PATCHES_REPO_DIR/$PATCHES_SUBDIR' not found."
        exit 1
    fi

    cd "$FIREFOX_SOURCE_DIR"
    echo "Current directory: $(pwd)"

    echo "Cleaning Firefox source directory before applying patches..."
    # Determine the current branch to reset properly
    local current_branch_ff=$(git symbolic-ref --short HEAD || git rev-parse HEAD)
    git checkout "$current_branch_ff" # Ensure we are on a branch
    git reset --hard "origin/$current_branch_ff" # Reset to its remote counterpart
    git clean -fdx

    # Apply patches in lexicographical order
    find "$PATCHES_REPO_DIR/$PATCHES_SUBDIR" -type f -name "*.patch" | sort | while IFS= read -r patch_file; do
        echo "Applying $(basename "$patch_file")..."
        if git apply --check --verbose "$patch_file"; then
            git apply --verbose "$patch_file"
        else
            echo "ERROR: Failed to apply patch $(basename "$patch_file") cleanly."
            echo "Attempting to apply with --reject to see conflicts..."
            if git apply --reject --verbose "$patch_file"; then
                echo "Patch applied with .rej files. Please inspect conflicts in $FIREFOX_SOURCE_DIR."
            else
                echo "FATAL: Could not even apply patch with --reject. Patch: $(basename "$patch_file")"
            fi
            # Decide if you want to exit on any failure or try to continue
            # For now, let's make it fatal for a clear failure
            exit 1
        fi
    done
    echo ">>> Patches applied."
    cd "$SCRIPT_DIR"
}

# --- Main Script ---

echo "Starting Firefox Fork Build Process..."

# 0. Check for necessary commands
ensure_command_exists "git"

# 1. Fetch/Update Firefox Source Code
# Pass the desired default branch for Firefox source if different from remote's HEAD branch
fetch_repo "$FIREFOX_SOURCE_URL" "$FIREFOX_SOURCE_DIR" "$DEFAULT_FIREFOX_BRANCH"

# 2. Fetch/Update Your Patches Repository
# For patches repo, we typically want its default branch (master/main)
fetch_repo "$PATCHES_REPO_URL" "$PATCHES_REPO_DIR" # No specific branch, use remote's default

# 3. Apply Patches
apply_patches_from_repo

# --- Placeholder for Build Steps (will add later) ---
echo ">>> Firefox source patched. Next steps would be configuring and building."
echo "To manually build (example, needs mozconfig setup):"
echo "cd $FIREFOX_SOURCE_DIR"
echo "# Create/copy your .mozconfig file here"
echo "# If it's your first time or dependencies changed:"
echo "# On Linux: ./mach bootstrap"
echo "# On macOS: ./mach bootstrap --no-system-changes (assuming system deps are installed via Homebrew, etc.)"
echo "# Then: ./mach build"
echo "# And to run: ./mach run"

echo ">>> Script finished."
