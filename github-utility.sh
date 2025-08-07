#!/bin/bash

# Interactive Branch Cleanup Script
# Compares local branches with merged GitHub PRs and helps clean up

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if GitHub CLI is installed
check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_color $RED "GitHub CLI (gh) is not installed!"
        print_color $YELLOW "Please install it first:"
        print_color $BLUE "  macOS: brew install gh"
        print_color $BLUE "  Ubuntu/Debian: sudo apt install gh"
        print_color $BLUE "  Windows: winget install GitHub.cli"
        print_color $BLUE "  Or visit: https://cli.github.com/"
        exit 1
    fi
}

# Function to check if user is authenticated with GitHub
check_gh_auth() {
    if ! gh auth status &> /dev/null; then
        print_color $RED "You're not authenticated with GitHub CLI!"
        print_color $YELLOW "Please authenticate first:"
        print_color $BLUE "  gh auth login"
        exit 1
    fi
}

# Function to check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --git-dir &> /dev/null; then
        print_color $RED "Not in a git repository!"
        exit 1
    fi
}

# Function to get the default branch (main or master)
get_default_branch() {
    local default_branch=$(git remote show origin | grep "HEAD branch" | cut -d' ' -f5)
    if [ -z "$default_branch" ]; then
        # Fallback to common default branches
        if git show-ref --verify --quiet refs/heads/main; then
            default_branch="main"
        elif git show-ref --verify --quiet refs/heads/master; then
            default_branch="master"
        else
            print_color $RED "Could not determine default branch!"
            exit 1
        fi
    fi
    echo "$default_branch"
}

# Function to display menu
show_menu() {
    print_color $BLUE "\n=== Branch Cleanup Menu ==="
    echo "1. List all merged PRs"
    echo "2. Check specific branch against merged PRs"
    echo "3. List local branches that have merged PRs"
    echo "4. Clean up merged local branches (safe)"
    echo "5. Update from remote and prune"
    echo "6. Show branch status summary"
    echo "7. Exit"
    echo -n "Choose an option (1-7): "
}

# Function to list merged PRs
list_merged_prs() {
    print_color $GREEN "\n📋  Recent merged PRs:"
    gh pr list --state merged --limit 20 --json number,title,headRefName,mergedAt,author --template '
{{- range . -}}
PR #{{.number}}: {{.title}}
  Branch: {{.headRefName}}
  Author: {{.author.login}}
  Merged: {{timeago .mergedAt}}

{{- end -}}'
}

# Function to check specific branch
check_specific_branch() {
    echo -n "Enter branch name to check: "
    read branch_name

    if [ -z "$branch_name" ]; then
        print_color $RED "Branch name cannot be empty!"
        return
    fi

    # Check if branch exists locally
    if ! git show-ref --verify --quiet refs/heads/"$branch_name"; then
        print_color $YELLOW "Branch '$branch_name' doesn't exist locally."
    else
        print_color $GREEN "Branch '$branch_name' exists locally."
    fi

    # Check if there's a merged PR for this branch
    local pr_info=$(gh pr list --state merged --head "$branch_name" --json number,title,mergedAt --template '
{{- range . -}}
PR #{{.number}}: {{.title}} (merged {{timeago .mergedAt}})
{{- end -}}')

    if [ -n "$pr_info" ]; then
        print_color $GREEN "✅  Found merged PR for '$branch_name':"
        echo "$pr_info"
    else
        print_color $YELLOW "❌  No merged PR found for '$branch_name'"
    fi
}

# Function to list local branches with merged PRs
list_local_merged_branches() {
    print_color $GREEN "\n🔍  Checking local branches against merged PRs..."

    local default_branch=$(get_default_branch)
    local branches_to_check=($(git branch --format='%(refname:short)' | grep -v "$default_branch"))

    if [ ${#branches_to_check[@]} -eq 0 ]; then
        print_color $YELLOW "No local branches found (other than $default_branch)"
        return
    fi

    echo -e "\n${BLUE}Local branches with merged PRs:${NC}"
    local found_merged=false

    for branch in "${branches_to_check[@]}"; do
        local pr_info=$(gh pr list --state merged --head "$branch" --json number,title,mergedAt --template '
{{- range . -}}
#{{.number}}: {{.title}} ({{timeago .mergedAt}})
{{- end -}}')

        if [ -n "$pr_info" ]; then
            print_color $GREEN "  ✅  $branch -> $pr_info"
            found_merged=true
        fi
    done

    if [ "$found_merged" = false ]; then
        print_color $YELLOW "No local branches have merged PRs"
    fi
}

# Function to safely clean up merged branches
cleanup_merged_branches() {
    print_color $GREEN "\n🧹  Safe cleanup of merged branches..."

    local default_branch=$(get_default_branch)

    # Switch to default branch first
    print_color $BLUE "Switching to $default_branch..."
    git checkout "$default_branch"

    # Pull latest changes
    print_color $BLUE "Pulling latest changes..."
    git pull origin "$default_branch"

    # Get list of merged branches
    local merged_branches=($(git branch --merged "$default_branch" | grep -v "$default_branch" | grep -v "^\*" | tr -d ' '))

    if [ ${#merged_branches[@]} -eq 0 ]; then
        print_color $YELLOW "No merged branches to clean up"
        return
    fi

    echo -e "\n${BLUE}Branches that appear to be merged:${NC}"
    for branch in "${merged_branches[@]}"; do
        # Double-check with GitHub PR status
        local pr_info=$(gh pr list --state merged --head "$branch" --json number --template '{{range .}}{{.number}}{{end}}')
        if [ -n "$pr_info" ]; then
            echo "  ✅  $branch (PR #$pr_info)"
        else
            echo "  ⚠️  $branch (no PR found - may be direct merge)"
        fi
    done

    echo -n -e "\n${YELLOW}Delete these branches? (y/N): ${NC}"
    read confirm

    if [[ $confirm =~ ^[Yy]$ ]]; then
        for branch in "${merged_branches[@]}"; do
            print_color $GREEN "Deleting $branch..."
            git branch -d "$branch"
        done
        print_color $GREEN "✅  Cleanup complete!"
    else
        print_color $YELLOW "Cleanup cancelled."
    fi
}

# Function to update from remote and prune
update_and_prune() {
    print_color $GREEN "\n🔄  Updating from remote and pruning..."

    local default_branch=$(get_default_branch)

    # Fetch with prune
    print_color $BLUE "Fetching latest changes and pruning..."
    git fetch origin --prune

    # Show what would be pruned
    print_color $BLUE "Remote tracking branches that were pruned:"
    git remote prune origin --dry-run

    # Switch to default branch and pull
    print_color $BLUE "Switching to $default_branch and pulling..."
    git checkout "$default_branch"
    git pull origin "$default_branch"

    print_color $GREEN "✅  Update complete!"
}

# Function to show branch status summary
show_branch_summary() {
    print_color $GREEN "\n📊  Branch Status Summary"

    local default_branch=$(get_default_branch)

    echo -e "\n${BLUE}Current branch:${NC}"
    git branch --show-current

    echo -e "\n${BLUE}Local branches:${NC}"
    git branch --format='%(refname:short)' | while read branch; do
        if [ "$branch" = "$default_branch" ]; then
            echo "  🏠  $branch (default)"
        else
            echo "  📝  $branch"
        fi
    done

    echo -e "\n${BLUE}Recent merged PRs (last 10):${NC}"
    gh pr list --state merged --limit 10 --json number,title,headRefName --template '{{range .}}  - PR #{{.number}}: {{.title}} ({{.headRefName}}){{"\n"}}{{end}}'
}

# Main script execution
main() {
    print_color $BLUE "🚀  Interactive Branch Cleanup Tool"

    # Check prerequisites
    check_gh_cli
    check_gh_auth
    check_git_repo

    # Main loop
    while true; do
        show_menu
        read choice

        case $choice in
            1)
                list_merged_prs
                ;;
            2)
                check_specific_branch
                ;;
            3)
                list_local_merged_branches
                ;;
            4)
                cleanup_merged_branches
                ;;
            5)
                update_and_prune
                ;;
            6)
                show_branch_summary
                ;;
            7)
                print_color $GREEN "👋  Goodbye!"
                exit 0
                ;;
            *)
                print_color $RED "Invalid option! Please choose 1-7."
                ;;
        esac

        echo -e "\n${YELLOW}Press Enter to continue...${NC}"
        read
    done
}

# Run the script
main