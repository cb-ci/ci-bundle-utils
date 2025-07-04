#!/usr/bin/env bash
# This script is used to export a bundle and push changes to the remote repository.

set -euo pipefail

if [[ "${DEBUG_SCRIPT:-}" == "true" ]]; then
  set -x
fi

function summary() {
  echo "BUNDLES: Bundle export complete. Showing last commits if any..."
  git --no-pager log -n 20 --pretty=format:"%h %ad - %s" --stat 2> /dev/null || true

  # Summary of the bundle-management
  if [[ -f "target/bundle-management.log" ]]; then
    echo "######################################"
    echo "BUNDLES: Summary of the export so far:"
    echo "######################################"
    cat "target/bundle-management.log"
    echo "######################################"
  fi
  # check for ERROR_FOUND=1
  if [[ "${1:-}" == "cjoc-and-online-controllers" ]] && [[ "$ERRORS_FOUND_ON_CONTROLLERS" == "1" ]]; then
    echo "BUNDLES: Errors found during export. Please check the output."
    exit 1
  fi
}

trap summary EXIT

GIT_ACTION="${GIT_ACTION:-commit-only}"
mandatory_envs="BUNDLEUTILS_USERNAME BUNDLEUTILS_PASSWORD JENKINS_URL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_ACTION"
usage_message="Usage: ./bundle-management.sh [setup|help|cjoc-and-online-controllers|<jenkins-url>]
  ./bundle-management.sh setup         - Setup the bundleutils environment variables.
  ./bundle-management.sh help          - Show this help message.
  ./bundle-management.sh cjoc-and-online-controllers - Audit all online controllers and the OC.
  ./bundle-management.sh <jenkins-url> - Fetch from this URL regardless (keeping the other variables).

  Mandatory environment variables (configured manually or using setup):
    BUNDLEUTILS_USERNAME   - Your bundleutils username.
    BUNDLEUTILS_PASSWORD   - Your bundleutils password.
    JENKINS_URL            - The Jenkins URL to fetch the bundle from.
    GIT_COMMITTER_NAME     - The name to use for git commits.
    GIT_COMMITTER_EMAIL    - The email to use for git commits.
    GIT_ACTION             - The git action to perform (do-nothing, add-only, commit-only, push).
"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################
#### ENVIRONMENT VARIABLES ####
###############################

function source_env() {
  # shellcheck disable=SC1091
  [ ! -f ".bundleutils.env" ] || source .bundleutils.env
}
source_env

mkdir -p target
echo > target/bundle-management.log
if [[ "${1:-}" == "help" ]]; then
  echo -e "$usage_message"
  exit 0
elif [[ "${1:-}" == "cjoc-and-online-controllers" ]]; then
  ERRORS_FOUND_ON_CONTROLLERS=0
  # List all controllers
  ONLINE_CONTROLLERS=$(bundleutils controllers)
  if [[ -z "$ONLINE_CONTROLLERS" ]]; then
    echo "BUNDLES: No online controllers found."
  else
    echo
    echo
    echo "BUNDLES: Exporting the following ONLINE controllers and then the OC:"
    echo "$ONLINE_CONTROLLERS"
    echo
    echo
    sleep 5
  fi
  mkdir -p target
  echo > target/bundle-management-all.log
  for CONTROLLER in $ONLINE_CONTROLLERS; do
    CONTROLLER_NAME=$(BUNDLEUTILS_JENKINS_URL="$CONTROLLER" bundleutils extract-name-from-url)
    echo "BUNDLES: Found online controller: $CONTROLLER"
    # Fetch the bundle from the controller
    if BUNDLEUTILS_JENKINS_URL="$CONTROLLER" bundleutils preflight; then
      echo "BUNDLES: $CONTROLLER_NAME - Preflight checks PASSED." | tee -a target/bundle-management.log
    else
      echo "BUNDLES: $CONTROLLER_NAME - Preflight checks FAILED." | tee -a target/bundle-management.log
      continue
    fi
    # Fetch the bundle from the controller
    if BUNDLEUTILS_JENKINS_URL="$CONTROLLER" $0; then
      echo "BUNDLES: $CONTROLLER_NAME - Bundle fetch PASSED." | tee -a target/bundle-management.log
    else
      echo "BUNDLES: $CONTROLLER_NAME - Bundle fetch FAILED." | tee -a target/bundle-management.log
      ERRORS_FOUND_ON_CONTROLLERS=1
    fi
    cat target/bundle-management.log >> target/bundle-management-all.log
  done
  cat target/bundle-management-all.log > target/bundle-management.log
elif [[ "${1:-}" == "setup" ]]; then
  if [[ ! -t 0 ]]; then
    echo "BUNDLES: Error: Setup requires a terminal to run."
    exit 1
  fi
  # Setup script for the bundleutils
  echo "BUNDLES: Setting up bundleutils..."
  GIT_ACTION="${GIT_ACTION:-commit-only}"
  mandatory_envs="BUNDLEUTILS_USERNAME BUNDLEUTILS_PASSWORD JENKINS_URL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_ACTION"
  output=""
  # check if mandatory envs are set, if not, prompt for them
  for env in $mandatory_envs; do
    current_value="${!env:-}"
    # if the env name contains PASSWORD, do not show the current value and hide the input on read
    if [[ "$env" == *PASSWORD* ]]; then
      # if current_value is empty, show -EMPTY- instead of -HIDDEN-
      if [[ -z "$current_value" ]]; then
        current_value_display="-EMPTY-"
      else
        current_value_display="-HIDDEN-"
      fi
      read -rsp "BUNDLES: Please enter your ${env} (current: $current_value_display): " input
      echo
    else
      # show the current value for all other envs
      read -rp "BUNDLES: Please enter your ${env} (current: $current_value): " input
    fi
    # if input is empty, use the current value
    if [[ -z "$input" ]]; then
      input="$current_value"
    fi
    output+="export $env=$input\n"
    [[ "$env" != "GIT_COMMITTER_NAME" ]] || output+="export GIT_AUTHOR_NAME=$input\n"
    [[ "$env" != "GIT_COMMITTER_EMAIL" ]] || output+="export GIT_AUTHOR_EMAIL=$input\n"
  done
  echo -e "$output" > .bundleutils.env
  source_env
  echo "BUNDLES: Bundleutils setup complete. Saved to .bundleutils.env - do not share this file or check into git."
  read -rp "BUNDLES: Do you wish to run the bundle-management now? (Y/n): " input
  if [[ "$input" =~ ^[Nn]$ ]]; then
    echo "BUNDLES: Audit skipped. You can run it later with: ./bundle-management.sh"
    exit 0
  else
    echo "BUNDLES: Performing bundle-management..."
  fi
fi

# Git actions environment variable: do-nothing, add-only, commit-only, push
if [[ -z "${GIT_ACTION:-}" ]]; then
  GIT_ACTION="do-nothing"
elif [[ ! "${GIT_ACTION:-}" =~ ^(do-nothing|add-only|commit-only|push)$ ]]; then
  echo "BUNDLES: Error: Invalid GIT_ACTION value. Must be one of: do-nothing, add-only, commit-only, push."
  exit 1
fi

GIT_ACTION_ADD=$([[ "${GIT_ACTION}" =~ ^(add-only|commit-only|push)$ ]] && echo 'true' || echo 'false')
GIT_ACTION_COMMIT=$([[ "${GIT_ACTION}" =~ ^(commit-only|push)$ ]] && echo 'true' || echo 'false')
GIT_ACTION_PUSH=$([[ "${GIT_ACTION}" == "push" ]] && echo 'true' || echo 'false')
GIT_BUNDLE_PRESERVE_HISTORY="${GIT_BUNDLE_PRESERVE_HISTORY:-}"
echo "BUNDLES: GIT_ACTION=${GIT_ACTION}"

# Check mandatory environment variables function
check_envs() {
  local vars="${1:-}"
  local reason="${2:-"No reason provided"}"
  for var in $vars; do
    if [[ -z "${!var:-}" ]]; then
      echo "BUNDLES: Error: Environment variable $var is not set. ${reason}."
      exit 1
    fi
  done
}
check_envs "BUNDLEUTILS_PASSWORD BUNDLEUTILS_USERNAME" "Jenkins API token needed to fetch the bundle"
check_envs "JENKINS_URL" "Jenkins URL needed to fetch the bundle"

function migrate_bundle() {
  echo "BUNDLES: Migrating from previous version $LAST_KNOWN_VERSION to $BUNDLE_DIR"
  if [[ "$GIT_ACTION_COMMIT" == "true" ]]; then
    git mv "$LAST_KNOWN_VERSION"  "$BUNDLE_DIR"
    git commit -m "Renaming $LAST_KNOWN_VERSION to $BUNDLE_DIR to preserve the git history" "$LAST_KNOWN_VERSION" "$BUNDLE_DIR"
    cp -r "$BUNDLE_DIR" "$LAST_KNOWN_VERSION"
    git add "$LAST_KNOWN_VERSION"
    git commit -m "Last known state of $LAST_KNOWN_VERSION before moving to $BUNDLE_DIR"
  fi
}

###############################
#### BUNDLEUTILS COMMANDS  ####
###############################

# This will ensure all plugins are left in the bundle.
# If you want to remove dependencies, etc, comment the following lines:
# export BUNDLEUTILS_PLUGINS_JSON_MERGE_STRATEGY='ALL'
# export BUNDLEUTILS_PLUGINS_JSON_LIST_STRATEGY='ALL'

# Get bundle name from the URL
echo "BUNDLES: Running bundleutils config..."
bundleutils transform --config-key

# Get the CI version
echo "BUNDLES: Export the instance version to avoid fetching it every time..."
BUNDLEUTILS_CI_VERSION=$(bundleutils extract-version-from-url)
export BUNDLEUTILS_CI_VERSION

# If we are appending the version to the bundle name, are we migrating from a previous version?
# Get the current final bundle directory
BUNDLE_DIR="$(bundleutils transform --config-key BUNDLEUTILS_TRANSFORM_TARGET_DIR)"
APPEND_VERSION="$(bundleutils transform --config-key BUNDLEUTILS_GBL_APPEND_VERSION)"
if [[ "$APPEND_VERSION" == "true" ]] && [[ ! -d "$BUNDLE_DIR" ]]; then
  echo "BUNDLES: Bundle $BUNDLE_DIR not found. Looking for a previous version..."
  LAST_KNOWN_VERSION="$(bundleutils transform --config-key BUNDLEUTILS_LAST_KNOWN_VERSION)"
  if [[ -n "$LAST_KNOWN_VERSION" ]]; then
    if [[ "$GIT_BUNDLE_PRESERVE_HISTORY" == "true" ]]; then
      migrate_bundle
    elif [[ "$GIT_BUNDLE_PRESERVE_HISTORY" == "false" ]]; then
      echo "BUNDLES: Bundle $BUNDLE_DIR will be created. Original bundle $LAST_KNOWN_VERSION will be left as is."
    else
      echo "BUNDLES: Decision time!!! The $BUNDLE_DIR is not found. The last known version is $LAST_KNOWN_VERSION."
      echo "BUNDLES: The GIT_BUNDLE_PRESERVE_HISTORY is not set. Please set it to true or false."
      echo "BUNDLES: - true:  If you want to preserve the history of $LAST_KNOWN_VERSION by renaming it to $BUNDLE_DIR, and re-adding the old bundle."
      echo "BUNDLES: - false: If you want to keep the history of $LAST_KNOWN_VERSION and start a new history for $BUNDLE_DIR"
      exit 1
    fi
  fi
fi

bundleutils fetch

# Sanitize the fetched bundle
echo "BUNDLES: Running bundleutils transform..."
bundleutils transform

# Sanitize the fetched bundle
echo "BUNDLES: Running bundleutils validate..."
if ! bundleutils validate; then
  echo "BUNDLES: Bundle validation failed. Please check the output." | tee -a target/bundle-management.log
else
  echo "BUNDLES: Bundle validation PASSED." | tee -a target/bundle-management.log
fi


# list the bundle files
echo "BUNDLES: Listing bundle files..."
BUNDLE_DIR="$(bundleutils transform --config-key BUNDLEUTILS_TRANSFORM_TARGET_DIR)"
find "$BUNDLE_DIR"

# Check if git command exists and directory is a git repository
if ! command -v git &> /dev/null; then
  echo "BUNDLES: Git command not found. Skipping git actions."
  exit 0
fi
if ! git rev-parse --is-inside-work-tree &> /dev/null; then
  echo "BUNDLES: Not a git repository. Skipping git actions."
  exit 0
fi

###############################
####       GIT LOGIC       ####
###############################

# gitleaks check
gitleaks_check() {
  GITLEAKS_CHECK="${GITLEAKS_CHECK:-staged}"
  if [[ "${GITLEAKS_CHECK}" == "none" ]]; then
    echo "BUNDLES: Skipping gitleaks check due to GITLEAKS_CHECK=none."
  else
    echo "BUNDLES: Running gitleaks check with gitleaks version $(gitleaks version)"
    # Get config
    if [[ -n "${GITLEAKS_CONFIG:-}" ]]; then
      echo "BUNDLES: Using GITLEAKS_CONFIG=$GITLEAKS_CONFIG"
    else
      echo "BUNDLES: No GITLEAKS_CONFIG found in env."
      if [[ "${GITLEAKS_USE_EMBEDDED_CONFIG:-true}" == "true" ]]; then
        export GITLEAKS_CONFIG="${SCRIPT_DIR}/.gitleaks.toml"
        echo "BUNDLES: GITLEAKS_USE_EMBEDDED_CONFIG=true. Using embedded config: $GITLEAKS_CONFIG"
      fi
    fi
    # Check runs
    case "${GITLEAKS_CHECK}" in
      none)
        echo "BUNDLES: Skipping gitleaks check..."
        ;;
      all)
        echo "BUNDLES: Running gitleaks check on all files..."
        if gitleaks git --no-color --verbose --redact --log-opts "$BUNDLE_DIR"; then
          echo "BUNDLES: $BUNDLE_DIR - Gitleaks check PASSED." | tee -a target/bundle-management.log
        else
          echo "BUNDLES: $BUNDLE_DIR - Gitleaks check FAILED. Please check the output." | tee -a target/bundle-management.log
          exit 1
        fi
        ;&
      *)
        if [[ "${GITLEAKS_CHECK}" != "staged" ]]; then
          echo "BUNDLES: GITLEAKS_CHECK is set to '$GITLEAKS_CHECK', not [all|staged]. Defaulting to staged."
        fi
        echo "BUNDLES: Running gitleaks check on staged files..."
        if gitleaks git --no-color --staged --verbose --redact --log-opts "$BUNDLE_DIR"; then
          echo "BUNDLES: $BUNDLE_DIR - Gitleaks check PASSED (staged files)." | tee -a target/bundle-management.log
        else
          echo "BUNDLES: $BUNDLE_DIR - Gitleaks check FAILED (staged files)" | tee -a target/bundle-management.log
          echo "BUNDLES: Unstaging files in $BUNDLE_DIR..."
          git ls-files "$BUNDLE_DIR" | xargs -r -- git restore --staged --
          git ls-files "$BUNDLE_DIR" | xargs -r -- git restore --
          exit 1
        fi
        ;;
    esac
  fi
}

# Git actions
GIT_ORIGIN="${GIT_ORIGIN:-"origin"}"
GIT_MAIN="${GIT_MAIN:-"main"}"
GIT_CURRENT_BRANCH="$(git branch --show-current)"
echo "BUNDLES: GIT_ORIGIN=$GIT_ORIGIN"
echo "BUNDLES: GIT_MAIN=$GIT_MAIN"
echo "BUNDLES: GIT_CURRENT_BRANCH=$GIT_CURRENT_BRANCH"
echo "BUNDLES: GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME"
echo "BUNDLES: GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL"
echo "BUNDLES: GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME"
echo "BUNDLES: GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL"

if [ -d "$BUNDLE_DIR" ]; then
  if [[ "$GIT_ACTION_ADD" == "true" ]]; then
    git add "$BUNDLE_DIR"
    gitleaks_check
    if git diff --cached --stat --exit-code "$BUNDLE_DIR"; then
      echo "BUNDLES: $BUNDLE_DIR - Git check. No changes to commit." | tee -a target/bundle-management.log
    else
      if [[ "$GIT_ACTION_COMMIT" == "true" ]]; then
        echo "BUNDLES: $BUNDLE_DIR - Git check. Committed changes." | tee -a target/bundle-management.log
        git commit -m "Audit bundle $BUNDLE_DIR (version: $BUNDLEUTILS_CI_VERSION)" "$BUNDLE_DIR"
        echo "BUNDLES: Commit: $(git --no-pager log -n1 --pretty=format:"YOUR_GIT_REPO/commit/%h %s")"

        if [[ "$GIT_ACTION_PUSH" == "true" ]]; then
          echo "BUNDLES: $BUNDLE_DIR - Git check. Pushed changes." | tee -a target/bundle-management.log
          git push "${GIT_ORIGIN}" "${GIT_CURRENT_BRANCH}"
          echo "BUNDLES: Pushed to YOUR_GIT_REPO/tree/$GIT_CURRENT_BRANCH"
        fi
      fi
    fi
  fi
else
  echo "BUNDLES: Bundle $BUNDLE_DIR not found. No changes to commit or push."
fi
cat target/bundle-management.log
