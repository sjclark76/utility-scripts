#!/bin/bash

# Stand up.sh - A script to generate a daily stand-up message using Linear tickets
# from a markdown file.
#
# Usage: ./stand up.sh
#
# This script will:
# 1. Check for dependencies (curl, jq).
# 2. Prompt for a Linear API key if not already configured.
# 3. Read 'tickets.md' line by line, handling tickets and manual entries.
# 4. Fetch the title for each ticket.
# 5. Prompt for what you plan to work on and any blockers.
# 6. Format the final message and copy it to the clipboard.
# 7. Clear the 'tickets.md' file for the next day.

# --- Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status.

LINEAR_API_URL="https://api.linear.app/graphql"
# Get the directory where the script is located
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/.env"
GITIGNORE_FILE="$SCRIPT_DIR/.gitignore"
TICKETS_FILE="$SCRIPT_DIR/tickets.md"

# --- Helper Functions ---

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Log an error message and exit
fail() {
  echo "❌ Error: $1" >&2
  exit 1
}

# Log a success message
success() {
  echo "✅ $1"
}

# Log an info message
info() {
  echo "ℹ️ $1"
}

# --- Main Script ---

# 1. Check for dependencies
if ! command_exists curl || ! command_exists jq; then
  fail "This script requires 'curl' and 'jq'. Please install them and try again."
fi

# 2. Handle Linear API Key
if [ ! -f "$ENV_FILE" ] || ! grep -q "LINEAR_API_KEY" "$ENV_FILE"; then
  info "Linear API key not found."
  read -sp "Please enter your Linear API key: " api_key
  echo # Newline after password prompt
  if [ -z "$api_key" ]; then
    fail "API key cannot be empty."
  fi
  echo "LINEAR_API_KEY=$api_key" >"$ENV_FILE"
  success "API key saved to $ENV_FILE"

  # Ensure .env is in .gitignore
  if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -q "$ENV_FILE" "$GITIGNORE_FILE"; then
      echo "$ENV_FILE" >>"$GITIGNORE_FILE"
    fi
  else
    echo "$ENV_FILE" >"$GITIGNORE_FILE"
  fi
fi

# Load the environment variables
# shellcheck source=.env
source "$ENV_FILE"

if [ -z "$LINEAR_API_KEY" ]; then
  fail "LINEAR_API_KEY is not set in $ENV_FILE. Please add it."
fi

# 3. Check for tickets.md
if [ ! -f "$TICKETS_FILE" ]; then
  echo "# Add Linear ticket numbers or tasks here, one per line." >"$TICKETS_FILE"
  info "Created '$TICKETS_FILE'. Please add your tickets/tasks to it and run the script again."
  exit 0
fi

info "Processing tickets and tasks from '$TICKETS_FILE'..."

# 4. Process tickets.md line by line
work_done_list=()
while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove trailing carriage return if it exists
    line=${line%$'\r'}

    # Skip empty lines or lines that are only whitespace
    if [[ -z "${line// }" ]]; then
        continue
    fi
    # Skip lines that are only comments
    if [[ "$line" =~ ^\s*# ]]; then
        continue
    fi

    # Regex to find a Linear-like ticket ID (e.g., ABC-123)
    ticket_regex="([A-Z]{2,}-[0-9]+)"

    if [[ "$line" =~ $ticket_regex ]]; then
        ticket_id="${BASH_REMATCH[1]}"
        # The rest of the line is the comment
        comment=$(echo "${line/$ticket_id/}" | xargs) # xargs trims whitespace

        # Construct the GraphQL query
        graphql_query=$(
jq -n --arg ticketId "$ticket_id" '{
          "query": "query issue($id: String!) { issue(id: $id) { title } }",
          "variables": {"id": $ticketId}
        }'
        )

        # Make the API call
        response=$(
curl -s -X POST "$LINEAR_API_URL" \
          -H "Authorization: $LINEAR_API_KEY" \
          -H "Content-Type: application/json" \
          --data "$graphql_query"
        )

        # Check for API errors
        if echo "$response" | jq -e '.errors' >/dev/null; then
            error_message=$(echo "$response" | jq -r '.errors[0].message')
            info "Could not fetch '$ticket_id': $error_message. Using line as is."
            work_done_list+=("  - $line")
            continue
        fi

        # Parse the title
        title=$(echo "$response" | jq -r '.data.issue.title')

        if [ "$title" != "null" ] && [ -n "$title" ]; then
            entry="  - $ticket_id: $title"
            if [ -n "$comment" ]; then
                entry+=" - $comment"
            fi
            work_done_list+=("$entry")
            echo "  - Fetched: $ticket_id"
        else
            info "Could not find title for '$ticket_id'. Using line as is."
            work_done_list+=("  - $line")
        fi
    else
        # No ticket ID found, treat the whole line as a task
        work_done_list+=("  - $line")
        info "  - Added manual entry: $line"
    fi
done < "$TICKETS_FILE"

if [ ${#work_done_list[@]} -eq 0 ]; then
  fail "No tasks or tickets found in '$TICKETS_FILE'."
fi

# 5. Prompt for other sections
echo
read -p "📝 What do you plan to work on? " plans
read -p "🤔 Any blockers? (leave empty for 'None') " blockers

# Set default for blockers if empty
blockers=${blockers:-"None"}

# 6. Assemble the final message
standup_message=$(
  cat <<EOF
1. *What have you been up to?*
$(printf '%s\n' "${work_done_list[@]}")

2. *What do you plan to work on?*
  - $plans

3. *Any blockers?*
  - $blockers
EOF
)

# Copy to clipboard
echo "$standup_message" | pbcopy

# 7. Clear the tickets.md file
echo "# Add Linear ticket numbers or tasks here, one per line." >"$TICKETS_FILE"

# 8. Final output
echo
success "Stand-up message has been copied to your clipboard!"
info "Cleared '$TICKETS_FILE' for next time. Paste the message into Slack."
