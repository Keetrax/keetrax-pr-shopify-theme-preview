#!/bin/bash
# Theme management functions for Shopify theme deployment scripts

# Source common utilities if not already loaded
[[ -z "${COMMON_UTILS_LOADED}" ]] && source "${BASH_SOURCE%/*}/common.sh" && COMMON_UTILS_LOADED=1
[[ -z "${GITHUB_API_LOADED}" ]] && source "${BASH_SOURCE%/*}/github.sh" && GITHUB_API_LOADED=1
[[ -z "${SLACK_API_LOADED}" ]] && source "${BASH_SOURCE%/*}/slack.sh" && SLACK_API_LOADED=1

# Function to cleanup a failed theme
cleanup_failed_theme() {
  local theme_id=$1
  echo "🧹 Attempting to cleanup theme ${theme_id}..."
  
  if shopify theme delete --theme "${theme_id}" --force 2>&1 | grep -q "Success"; then
    echo "✅ Successfully deleted theme ${theme_id}"
    return 0
  else
    echo "❌ Failed to delete theme ${theme_id}"
    return 1
  fi
}

# Helper function: check if theme exists by name in Shopify store
check_theme_exists_by_name() {
  local theme_name="$1"
  local theme_list
  
  echo "🔍 Checking if theme with name '${theme_name}' exists in Shopify store..." >&2
  
  if ! theme_list=$(shopify theme list --json 2>/dev/null); then
    echo "⚠️ Could not retrieve theme list from Shopify"
    return 1
  fi
  
  # Look for exact theme name match
  local found_theme_id
  found_theme_id=$(echo "$theme_list" | node -e "
    const fs = require('fs');
    const data = fs.readFileSync(0, 'utf8');
    const name = process.argv[1];
    try {
      const obj = JSON.parse(data);
      let themes;
      // Handle both array and object formats
      if (Array.isArray(obj)) {
        themes = obj;
      } else if (obj && obj.themes) {
        themes = obj.themes;
      } else {
        themes = [];
      }
      // Log theme names for debugging
      if (themes.length > 0) {
        const themeNames = themes.map(t => t.name);
        console.error('Found ' + themes.length + ' themes: ' + JSON.stringify(themeNames));
      }
      const found = themes.find(t => t.name === name);
      if (found) {
        console.error('✅ Found matching theme: ' + found.name + ' (ID: ' + found.id + ')');
      } else {
        console.error('❌ No match found for: ' + name);
      }
      console.log(found?.id || '');
    } catch(e) {
      console.error('Error parsing theme list:', e.message);
      console.error('Data received:', data.substring(0, 200));
      console.log('');
    }
  " -- "$theme_name" 2>&1 | grep -v "^Found\|^✅\|^❌\|^Error parsing\|^Data received" || true)
  
  if [ -n "$found_theme_id" ] && [ "$found_theme_id" != "null" ]; then
    echo "✅ Found existing theme with name '${theme_name}' (ID: ${found_theme_id})" >&2
    echo "$found_theme_id"
    return 0
  fi
  
  return 1
}

# Function to handle theme limit errors
handle_theme_limit() {
  echo "🔍 Checking for old PR preview themes to clean up..."
  
  local theme_list
  if ! theme_list=$(shopify theme list --json 2>/dev/null); then
    echo "⚠️ Could not retrieve theme list"
    return 1
  fi

  # Try to parse the JSON and find old preview themes
  local old_preview_themes
  old_preview_themes=$(echo "$theme_list" | node -e "
    const data = require('fs').readFileSync(0, 'utf8');
    try {
      const parsed = JSON.parse(data);
      let themes = [];
      
      // Handle both direct array and object with themes property
      if (Array.isArray(parsed)) {
        themes = parsed;
      } else if (parsed.themes && Array.isArray(parsed.themes)) {
        themes = parsed.themes;
      }
      
      // Filter for PR preview themes (unpublished, matching our naming pattern)
      const previewThemes = themes.filter(t => 
        t.role === 'unpublished' && 
        (t.name.includes('PR-') || t.name.includes('FLASH-'))
      ).map(t => ({id: t.id, name: t.name, updated_at: t.updated_at}));
      
      // Sort by update date (oldest first)
      previewThemes.sort((a, b) => new Date(a.updated_at) - new Date(b.updated_at));
      
      console.log(JSON.stringify(previewThemes));
    } catch (error) {
      console.error('Error parsing theme list:', error);
      console.log('[]');
    }
  " 2>/dev/null)

  local themes_deleted=0
  if [ -n "$old_preview_themes" ] && [ "$old_preview_themes" != "[]" ]; then
    # Try to delete the oldest preview themes
    local theme_ids
    theme_ids=$(echo "$old_preview_themes" | parse_json "" "[*].id" | tr '\n' ' ')
    
    for theme_id in $theme_ids; do
      if [ $themes_deleted -ge 2 ]; then
        break  # Delete at most 2 themes
      fi
      
      local theme_name
      theme_name=$(echo "$old_preview_themes" | node -e "
        const themes = JSON.parse(require('fs').readFileSync(0, 'utf8'));
        const theme = themes.find(t => t.id == '$theme_id');
        console.log(theme ? theme.name : '');
      ")
      
      echo "🗑️ Attempting to delete old preview theme: ${theme_name} (ID: ${theme_id})"
      if cleanup_failed_theme "$theme_id"; then
        themes_deleted=$((themes_deleted + 1))
      fi
    done
  fi

  if [ $themes_deleted -gt 0 ]; then
    echo "✅ Deleted ${themes_deleted} old preview theme(s)"
    return 0
  else
    echo "⚠️ No old preview themes found to delete"
    return 1
  fi
}

# Function to post error comment on PR
# Note: theme_id parameter is kept for backward compatibility but no longer used
# Themes with errors are always deleted, so we never show theme details in error comments
post_error_comment() {
  local error_message=$1
  local theme_id=$2  # Ignored - themes with errors are deleted
  
  echo "💬 Posting error comment to PR..."
  
  # Clean error message for better readability  
  local cleaned_error
  cleaned_error=$(clean_for_slack "$error_message")
  
  # Get store URL for context
  local store_url="${SHOPIFY_FLAG_STORE}"
  store_url="${store_url#https://}"
  store_url="${store_url#http://}"
  store_url="${store_url%/}"
  
  local comment_body
  comment_body=$(cat <<EOF
## ❌ Shopify Theme Preview Failed

Failed to create theme preview due to the following errors:

\`\`\`
${cleaned_error}
\`\`\`

### Store Info:
- **Store URL**: \`${store_url}\`

Please fix these issues and push your changes to trigger a new deployment.
EOF
)

  # Use the github_api function to post comment
  if post_pr_comment "$PR_NUMBER" "$comment_body"; then
    echo "✅ Error comment posted successfully"
  else
    echo "❌ Failed to post error comment"
  fi
}

# Helper function to build ignore flags from IGNORE_FILES env var
build_ignore_flags() {
  local ignore_flags=""
  if [ -n "$IGNORE_FILES" ]; then
    # Split comma-separated patterns and build --ignore flags
    IFS=',' read -ra patterns <<< "$IGNORE_FILES"
    for pattern in "${patterns[@]}"; do
      # Trim whitespace
      pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$pattern" ]; then
        ignore_flags="$ignore_flags --ignore=\"$pattern\""
      fi
    done
  fi
  echo "$ignore_flags"
}

# Return success when a repository path matches a caller-supplied ignore pattern
# or is the merchant-managed settings data file.
is_json_file_ignored() {
  local file_path="$1"

  if [ "$file_path" = "config/settings_data.json" ]; then
    return 0
  fi

  if [ -n "$IGNORE_FILES" ]; then
    local pattern
    local -a patterns=()
    IFS=',' read -ra patterns <<< "$IGNORE_FILES"
    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -n "$pattern" ] && [[ "$file_path" == $pattern ]]; then
        return 0
      fi
    done
  fi

  return 1
}

# Add repository JSON files that do not exist on an existing preview theme.
# Existing remote JSON is never pushed here, preserving merchant-edited settings.
push_missing_json_files() {
  local theme_id="$1"
  local theme_path="${THEME_ROOT:-.}"
  local remote_theme_path
  local pull_output
  local pull_status=0
  local push_output
  local push_status=0
  local parsed_json
  local error_count
  local warning_message
  local relative_path
  local -a missing_json_files=()
  local -a push_args=()

  remote_theme_path=$(mktemp -d)

  echo "🔎 Checking for repository JSON files missing from theme ID: ${theme_id}..."
  set +e -f
  pull_output=$(shopify theme pull \
    --theme "$theme_id" \
    --path "$remote_theme_path" \
    --only="*.json" \
    --nodelete \
    --no-color 2>&1)
  pull_status=$?
  set -e +f

  if [ "$pull_status" -ne 0 ]; then
    echo "❌ Could not read the target theme's JSON file list"
    printf '%s\n' "$pull_output"
    THEME_ERRORS="Failed to inspect existing theme JSON files: $pull_output"
    LAST_UPLOAD_OUTPUT="$pull_output"
    rm -rf "$remote_theme_path"
    return 1
  fi

  while IFS= read -r -d '' relative_path; do
    relative_path="${relative_path#./}"

    if is_json_file_ignored "$relative_path"; then
      echo "⏭️ Ignoring JSON file: ${relative_path}"
      continue
    fi

    if [ ! -f "$remote_theme_path/$relative_path" ]; then
      missing_json_files+=("$relative_path")
    fi
  done < <(
    cd "$theme_path"
    find config layout locales sections templates -type f -name '*.json' -print0 2>/dev/null
  )

  if [ "${#missing_json_files[@]}" -eq 0 ]; then
    echo "✅ No new repository JSON files to add"
    rm -rf "$remote_theme_path"
    return 0
  fi

  echo "📄 Adding ${#missing_json_files[@]} new JSON file(s) without overwriting existing theme JSON:"
  push_args=(shopify theme push \
    --theme "$theme_id" \
    --path "$theme_path" \
    --nodelete \
    --no-color \
    --json)

  for relative_path in "${missing_json_files[@]}"; do
    echo "  - ${relative_path}"
    push_args+=("--only=${relative_path}")
  done

  set +e -f
  push_output=$("${push_args[@]}" 2>&1)
  push_status=$?
  set -e +f
  LAST_UPLOAD_OUTPUT="$push_output"

  if [ "$push_status" -ne 0 ]; then
    echo "❌ Failed to add new JSON files"
    printf '%s\n' "$push_output"
    THEME_ERRORS="$push_output"
    rm -rf "$remote_theme_path"
    return 1
  fi

  parsed_json=$(printf '%s' "$push_output" | grep -o '{"theme":{.*}}$' | tail -1 || echo "")
  if [ -z "$parsed_json" ]; then
    parsed_json=$(printf '%s' "$push_output" | grep -o '{"theme":{.*}}' | tail -1 || echo "")
  fi

  if [ -n "$parsed_json" ]; then
    error_count=$(echo "$parsed_json" | extract_json_value "" "error_count")
    warning_message=$(echo "$parsed_json" | extract_json_value "" "warning")

    if [ -n "$error_count" ] && [ "$error_count" -gt 0 ]; then
      THEME_ERRORS=$(echo "$parsed_json" | extract_json_value "" "format_errors")
      [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$push_output"
      echo "❌ New JSON files failed theme validation"
      rm -rf "$remote_theme_path"
      return 1
    fi

    if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
      if [ -n "$THEME_ERRORS" ]; then
        THEME_ERRORS+=$'\n'
      fi
      THEME_ERRORS+="$warning_message"
      export THEME_ERRORS
    fi
  fi

  echo "✅ New repository JSON files added successfully"
  rm -rf "$remote_theme_path"
  return 0
}

# Function to upload theme to Shopify
upload_theme() {
  local theme_id=$1
  local include_json=${2:-true}  # Default to true for backward compatibility
  local status=0
  local parsed_json
  local error_count
  local warning_message
  
  # Use THEME_ROOT if set, otherwise default to current directory
  local theme_path="${THEME_ROOT:-.}"
  
  # Build custom ignore flags from IGNORE_FILES
  local custom_ignore_flags
  custom_ignore_flags=$(build_ignore_flags)
  
  THEME_ERRORS=""
  LAST_UPLOAD_OUTPUT=""
  
  # If we should not include JSON, add ignore flags for specific JSON files
  # Always push from codebase: config/settings_schema.json, locales/en.default.json, locales/en.default.schema.json
  # Never overwrite: config/settings_data.json, templates/*.json, sections/*.json, layout/*.json
  if [ "$include_json" = "false" ]; then
    echo "📤 Uploading theme to ID: ${theme_id} (preserving settings, always pushing locale & schema from codebase)..."
    set +e -f
    OUTPUT=$(eval shopify theme push \
      --theme \"$theme_id\" \
      --path \"$theme_path\" \
      --nodelete \
      --no-color \
      --json \
      --ignore=\"config/settings_data.json\" \
      --ignore=\"templates/*.json\" \
      --ignore=\"sections/*.json\" \
      --ignore=\"layout/*.json\" \
      $custom_ignore_flags 2>&1)
    status=$?
    set -e +f
  else
    echo "📤 Uploading theme to ID: ${theme_id}..."
    set +e -f
    OUTPUT=$(eval shopify theme push \
      --theme \"$theme_id\" \
      --path \"$theme_path\" \
      --nodelete \
      --no-color \
      --json \
      $custom_ignore_flags 2>&1)
    status=$?
    set -e +f
  fi
  
  LAST_UPLOAD_OUTPUT="$OUTPUT"
  
  # Try to parse JSON response
  parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}$' | tail -1 || echo "")
  if [ -z "$parsed_json" ]; then
    parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}' | tail -1 || echo "")
  fi

  if [ $status -eq 0 ]; then
    if [ -n "$parsed_json" ]; then
      error_count=$(echo "$parsed_json" | extract_json_value "" "error_count")
      warning_message=$(echo "$parsed_json" | extract_json_value "" "warning")

      if [ "$error_count" -eq 0 ]; then
        if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
          THEME_ERRORS="$warning_message"
          export THEME_ERRORS
        fi
        echo "✅ Theme updated successfully"
        return 0
      else
        THEME_ERRORS=$(echo "$parsed_json" | extract_json_value "" "format_errors")
        [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"
        echo "❌ Theme upload failed with validation errors"
        return 1
      fi
    else
      echo "✅ Theme updated successfully (no JSON response, assuming success)"
      return 0
    fi
  else
    THEME_ERRORS="$OUTPUT"
    # Check for "doesn't exist" or "not found" errors
    if echo "$OUTPUT" | grep -qi "doesn't exist\|not found"; then
      echo "❌ Theme ID ${theme_id} no longer exists on Shopify. Cannot update."
      return 1
    fi
    echo "❌ Theme upload failed"
    return 1
  fi
}

# Function to create theme (NO RETRY for validation errors)
create_theme_with_retry() {
  local theme_name="$1"
  local max_retries=1  # NO RETRIES except for rate limits
  local attempt=0
  local limit_cleanup_attempted=false
  
  # Use THEME_ROOT if set, otherwise default to current directory
  local theme_path="${THEME_ROOT:-.}"
  
  # Build custom ignore flags from IGNORE_FILES
  local custom_ignore_flags
  custom_ignore_flags=$(build_ignore_flags)

  CREATED_THEME_ID=""
  THEME_ERRORS=""
  LAST_UPLOAD_OUTPUT=""

  while [ $attempt -lt $max_retries ]; do
    if [ -z "$CREATED_THEME_ID" ]; then
      echo "🎨 Creating new theme: ${theme_name} (attempt $((attempt + 1)))"

      local status=0
      set +e -f
      OUTPUT=$(eval shopify theme push \
        --unpublished \
        --theme \"${theme_name}\" \
        --path \"$theme_path\" \
        --nodelete \
        --no-color \
        --json \
        $custom_ignore_flags 2>&1)
      status=$?
      set -e +f

      LAST_UPLOAD_OUTPUT="$OUTPUT"
      
      echo "🔍 Checking theme creation output..."

      # Only classify a failed push as a theme-limit error. Successful Shopify CLI
      # output can contain words such as "maximum" or "limit" in warnings or theme
      # content, so matching those words without checking the exit status creates
      # false failures after Shopify has already created the theme.
      local theme_limit_pattern="theme limit (reached|exceeded)|reached (the )?(maximum )?(number of )?themes|maximum (number of )?themes|too many themes|more than [0-9]+ themes"
      if [ "$status" -ne 0 ]; then
        echo "❌ Shopify theme push failed with exit status ${status}"
        echo "📝 Shopify CLI output:"
        printf '%s\n' "$OUTPUT"

        if echo "$OUTPUT" | grep -Eqi "$theme_limit_pattern"; then
          echo "⚠️ Theme limit error detected"
          if [ "$limit_cleanup_attempted" = false ] && handle_theme_limit; then
            limit_cleanup_attempted=true
            echo "🔄 Retrying theme creation after cleanup..."
            attempt=$((attempt + 1))
            sleep 2
            continue
          fi

          THEME_ERRORS="Theme limit reached and older previews could not be removed automatically."
          # Don't post comment here - let deploy.sh handle it
          return 1
        fi
      fi

      # Extract JSON from the output
      local parsed_json
      parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}$' | tail -1 || echo "")
      
      if [ -z "$parsed_json" ]; then
        parsed_json=$(printf '%s' "$OUTPUT" | grep -o '{"theme":{.*}}' | tail -1 || echo "")
      fi
      
      if [ -n "$parsed_json" ]; then
        echo "✅ Found JSON response from Shopify CLI"
        
        local parsed_theme_id
        parsed_theme_id=$(echo "$parsed_json" | extract_json_value "" "theme_id")
        [ "$parsed_theme_id" = "null" ] && parsed_theme_id=""
        if [ -n "$parsed_theme_id" ]; then
          CREATED_THEME_ID="$parsed_theme_id"
          THEME_ID="$CREATED_THEME_ID"
          export THEME_ID
          echo "✅ Theme created with ID: ${CREATED_THEME_ID}"
        fi

        # Check for errors in the JSON response
        local error_count
        error_count=$(echo "$parsed_json" | extract_json_value "" "error_count")
        local warning_message
        warning_message=$(echo "$parsed_json" | extract_json_value "" "warning")
        
        echo "📊 Theme creation result: error_count=${error_count}, has_warnings=$([ -n "$warning_message" ] && [ "$warning_message" != "null" ] && echo "yes" || echo "no")"

        if [ "$error_count" -gt 0 ]; then
          echo "❌ Theme was created with ${error_count} error(s)"
          THEME_ERRORS=$(echo "$parsed_json" | extract_json_value "" "format_errors")
          [ -z "$THEME_ERRORS" ] && THEME_ERRORS="$OUTPUT"
          
          # ALWAYS cleanup the failed theme immediately
          if [ -n "$CREATED_THEME_ID" ]; then
            echo "🧹 Cleaning up theme ${CREATED_THEME_ID} that was created with errors..."
            if cleanup_failed_theme "$CREATED_THEME_ID"; then
              echo "✅ Failed theme ${CREATED_THEME_ID} has been removed"
              CREATED_THEME_ID=""
            else
              echo "⚠️ WARNING: Could not cleanup failed theme ${CREATED_THEME_ID}"
            fi
          fi
          
          # Don't post comment here - let deploy.sh handle it
          # Just return failure
          echo "🛑 Stopping - validation errors cannot be fixed by retrying"
          return 1
        fi

        if [ -n "$warning_message" ] && [ "$warning_message" != "null" ]; then
          echo "⚠️ Theme created with warnings: $warning_message"
          THEME_ERRORS="$warning_message"
          export THEME_ERRORS
          return 0
        fi

        if [ -n "$CREATED_THEME_ID" ]; then
          echo "✅ Theme created successfully without errors!"
          return 0
        fi
        
        # If we get here, no theme ID was found in the JSON
        echo "❌ ERROR: JSON response didn't contain a theme ID"
        echo "📝 Full JSON was: $parsed_json"
        # Try to extract it manually
        local manual_theme_id
        manual_theme_id=$(echo "$parsed_json" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        if [ -n "$manual_theme_id" ]; then
          echo "🔍 Manually extracted theme ID: $manual_theme_id"
          CREATED_THEME_ID="$manual_theme_id"
          THEME_ID="$CREATED_THEME_ID"
          export THEME_ID
          return 0
        fi
        # If we still can't get the ID, fail immediately
        THEME_ERRORS="Failed to extract theme ID from Shopify response"
        return 1
      else
        # No JSON found - retry only for a failed push with a genuine theme-limit error
        if [ "$status" -ne 0 ] && echo "$OUTPUT" | grep -Eqi "$theme_limit_pattern"; then
          # Only retry for theme-limit errors
          attempt=$((attempt + 1))
          if [ $attempt -lt $max_retries ]; then
            echo "⚠️ Theme limit detected, waiting 30 seconds before retry..."
            sleep 30
            continue
          fi
        fi
        
        echo "❌ Theme creation failed"
        THEME_ERRORS="Failed to create theme: $OUTPUT"
        return 1
      fi
    fi

    # Should not reach here
    break
  done

  echo "❌ Failed to create theme"
  [ -n "$LAST_UPLOAD_OUTPUT" ] && echo "Last output: $LAST_UPLOAD_OUTPUT"

  # Always try to cleanup any partially created theme
  if [ -n "$CREATED_THEME_ID" ]; then
    echo "🧹 Attempting to cleanup failed theme ${CREATED_THEME_ID}..."
    if cleanup_failed_theme "$CREATED_THEME_ID"; then
      echo "✅ Failed theme ${CREATED_THEME_ID} cleaned up"
    else
      echo "⚠️ WARNING: Could not cleanup failed theme ${CREATED_THEME_ID}"
    fi
  fi

  return 1
}

# Export functions for use in other scripts
export -f build_ignore_flags
export -f is_json_file_ignored
export -f push_missing_json_files
export -f cleanup_failed_theme
export -f check_theme_exists_by_name
export -f handle_theme_limit
export -f post_error_comment
export -f upload_theme
export -f create_theme_with_retry
