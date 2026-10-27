import Foundation

class ScriptManager {
    static let shared = ScriptManager()

    private init() {}

    // MARK: - Gateway Command Installation

    func installGatewayCommand() throws -> String {
        let scriptContent = """
#!/bin/bash

# Gateway v2.0.0
# Interactive profile selection with per-terminal session persistence

PROFILE_HISTORY="$HOME/Library/Application Support/AWS CLI Gateway/profile_history.json"
AWS_CONFIG="$HOME/.aws/config"
AWS_CMD="/usr/local/bin/aws"
SESSION_DIR="/tmp/gateway-sessions"
TTY_HASH=$(tty 2>/dev/null | md5 -q 2>/dev/null || echo "$$")
SESSION_FILE="$SESSION_DIR/session-$TTY_HASH"

mkdir -p "$SESSION_DIR"

function check_requirements() {
    if [ ! -f "$PROFILE_HISTORY" ]; then
        echo "Error: Profile history not found. Run the Gateway app first." >&2
        exit 1
    fi
    if [ ! -x "$AWS_CMD" ]; then
        echo "Error: AWS CLI not found at $AWS_CMD" >&2
        exit 1
    fi
}

function get_connected_profiles() {
    python3 -c "
import json, sys
with open('$PROFILE_HISTORY', 'r') as f:
    data = json.load(f)
for p in data:
    if p.get('isConnected', False):
        print(p.get('originalName') + '|' + p.get('profileType', 'sso'))
" 2>/dev/null
}

function interactive_select() {
    local -a NAMES=()
    local -a TYPES=()

    while IFS='|' read -r name ptype; do
        NAMES+=("$name")
        TYPES+=("$ptype")
    done < <(get_connected_profiles)

    local COUNT=${#NAMES[@]}

    if [ "$COUNT" -eq 0 ]; then
        echo "No active sessions. Connect a profile in Gateway first." >&2
        exit 1
    fi

    if [ "$COUNT" -eq 1 ]; then
        echo "${NAMES[0]}"
        return
    fi

    local SELECTED=0
    local CURRENT_DEFAULT=""
    [ -f "$SESSION_FILE" ] && CURRENT_DEFAULT=$(cat "$SESSION_FILE")

    # Position cursor at current default if set
    for i in "${!NAMES[@]}"; do
        if [ "${NAMES[$i]}" == "$CURRENT_DEFAULT" ]; then
            SELECTED=$i
            break
        fi
    done

    # Hide cursor
    printf '\\e[?25l' >/dev/tty

    # Cleanup on exit
    trap 'printf "\\e[?25h" >/dev/tty' EXIT

    # Draw menu
    printf '\\n  Select a profile (↑/↓ to move, Enter to select, q to cancel):\\n\\n' >/dev/tty

    while true; do
        # Draw options
        for i in "${!NAMES[@]}"; do
            if [ "$i" -eq "$SELECTED" ]; then
                printf '\\e[1m  ▸ %s (%s)\\e[0m\\n' "${NAMES[$i]}" "${TYPES[$i]}" >/dev/tty
            else
                printf '    %s (%s)\\n' "${NAMES[$i]}" "${TYPES[$i]}" >/dev/tty
            fi
        done

        # Read keypress
        IFS= read -rsn1 KEY </dev/tty

        # Handle escape sequences (arrow keys)
        if [ "$KEY" == $'\\e' ]; then
            read -rsn2 SEQ </dev/tty
            case "$SEQ" in
                "[A") # Up
                    ((SELECTED > 0)) && ((SELECTED--))
                    ;;
                "[B") # Down
                    ((SELECTED < COUNT - 1)) && ((SELECTED++))
                    ;;
            esac
        elif [ "$KEY" == "" ]; then
            # Enter pressed
            break
        elif [ "$KEY" == "q" ] || [ "$KEY" == "Q" ]; then
            printf '\\e[?25h' >/dev/tty
            echo "Cancelled." >&2
            exit 0
        elif [ "$KEY" == "k" ]; then
            ((SELECTED > 0)) && ((SELECTED--))
        elif [ "$KEY" == "j" ]; then
            ((SELECTED < COUNT - 1)) && ((SELECTED++))
        fi

        # Move cursor back up to redraw
        printf '\\e[%dA' "$COUNT" >/dev/tty
    done

    # Show cursor
    printf '\\e[?25h' >/dev/tty

    echo "${NAMES[$SELECTED]}"
}

function use_profile() {
    local PROFILE
    PROFILE=$(interactive_select)
    if [ -n "$PROFILE" ]; then
        echo "$PROFILE" > "$SESSION_FILE"
        echo "Default profile set to: $PROFILE (this terminal)" >&2
    fi
}

function get_session_profile() {
    if [ -f "$SESSION_FILE" ]; then
        local SAVED
        SAVED=$(cat "$SESSION_FILE")
        # Verify saved profile is still connected
        if get_connected_profiles | grep -q "^${SAVED}|"; then
            echo "$SAVED"
            return
        fi
        rm -f "$SESSION_FILE"
    fi
    return 1
}

function get_active_profile() {
    # Check session default first
    local SESSION_PROFILE
    SESSION_PROFILE=$(get_session_profile) && { echo "$SESSION_PROFILE"; return; }

    # Fall back to interactive selection
    local PROFILE
    PROFILE=$(interactive_select)
    if [ -n "$PROFILE" ]; then
        echo "$PROFILE" > "$SESSION_FILE"
        echo "$PROFILE"
    fi
}

function list_profiles() {
    local TYPE=$1

    echo "Available $TYPE profiles:"
    echo "------------------------"

    if [ "$TYPE" == "sso" ]; then
        grep -B 1 -A 10 '\\[profile' "$AWS_CONFIG" |
        grep -v 'role_arn' |
        grep -A 1 'sso_' |
        grep '\\[profile' |
        sed 's/\\[profile \\(.*\\)\\]/\\1/'
    elif [ "$TYPE" == "role" ] || [ "$TYPE" == "iam" ]; then
        grep -B 1 -A 10 '\\[profile' "$AWS_CONFIG" |
        grep -B 1 'role_arn' |
        grep '\\[profile' |
        sed 's/\\[profile \\(.*\\)\\]/\\1/'
    else
        grep '\\[profile' "$AWS_CONFIG" |
        sed 's/\\[profile \\(.*\\)\\]/\\1/'
    fi
}

function show_status() {
    local CURRENT=""
    [ -f "$SESSION_FILE" ] && CURRENT=$(cat "$SESSION_FILE")

    echo "Gateway Session Status"
    echo "======================"
    if [ -n "$CURRENT" ]; then
        echo "Default profile: $CURRENT"
    else
        echo "Default profile: (none set — run 'gateway use' to select)"
    fi
    echo ""
    echo "Connected profiles:"
    while IFS='|' read -r name ptype; do
        if [ "$name" == "$CURRENT" ]; then
            printf '  ● %s (%s) ← active\\n' "$name" "$ptype"
        else
            printf '  ○ %s (%s)\\n' "$name" "$ptype"
        fi
    done < <(get_connected_profiles)
}

function debug_info() {
    echo "=== DEBUG INFO ==="
    echo "Script version: 2.0.0"
    echo "Profile history: $PROFILE_HISTORY"
    echo "Session file: $SESSION_FILE"
    echo "TTY: $(tty 2>/dev/null || echo 'unknown')"
    echo ""
    [ -f "$SESSION_FILE" ] && echo "Session default: $(cat "$SESSION_FILE")" || echo "Session default: (none)"
    echo ""
    echo "Profile history exists: $([ -f "$PROFILE_HISTORY" ] && echo "Yes" || echo "No")"
    if [ -f "$PROFILE_HISTORY" ]; then
        echo "Connected profiles:"
        get_connected_profiles | while IFS='|' read -r name ptype; do
            echo "  - $name ($ptype)"
        done
    fi
    echo ""
    echo "AWS CLI: $AWS_CMD ($([ -x "$AWS_CMD" ] && echo "found" || echo "missing"))"
    echo "AWS config: $([ -f "$AWS_CONFIG" ] && echo "found" || echo "missing")"
    echo "==================="
}

function show_help() {
    echo "Gateway v2.0.0"
    echo ""
    echo "USAGE:"
    echo "  gateway [OPTIONS] [AWS_COMMAND] [ARGS...]"
    echo ""
    echo "OPTIONS:"
    echo "  -u, use       Select default profile for this terminal (interactive)"
    echo "  -l, list      List all profiles (-l sso | -l role)"
    echo "  -s, status    Show current session and connected profiles"
    echo "  -d, debug     Show debug information"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  gateway use              Pick a profile interactively"
    echo "  gateway s3 ls            Run 'aws s3 ls' with session profile"
    echo "  gateway -l sso           List SSO profiles"
    echo "  gateway status           Show current session info"
    echo ""
    echo "BEHAVIOR:"
    echo "  The selected profile persists for this terminal session."
    echo "  Run 'gateway use' again to switch. Each terminal window is independent."
}

# Main
check_requirements

case "$1" in
    "-u"|"use")
        use_profile
        ;;
    "-l"|"list")
        if [ "$2" == "sso" ] || [ "$2" == "role" ] || [ "$2" == "iam" ]; then
            list_profiles "$2"
        else
            list_profiles "all"
        fi
        ;;
    "-s"|"status")
        show_status
        ;;
    "-d"|"debug")
        debug_info
        ;;
    "-h"|"--help"|"help")
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        PROFILE=$(get_active_profile)
        echo "Using profile: $PROFILE" >&2
        if [[ "$*" == *"--profile"* ]]; then
            $AWS_CMD "$@"
        else
            $AWS_CMD "$@" --profile "$PROFILE"
        fi
        ;;
esac
"""

        // Create a temporary file for the script
        let tempDirectory = FileManager.default.temporaryDirectory
        let scriptPath = tempDirectory.appendingPathComponent("gateway-script.sh")

        // Write script content to the temporary file
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)

        let destinationPath = "/usr/local/bin/gateway"

        // Create the AppleScript with proper quoting
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp '\(scriptPath.path)' '\(destinationPath)' && chmod +x '\(destinationPath)'" with administrator privileges
        """

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ScriptManager", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Installation failed: \(errorOutput)"])
        }

        return "The 'gateway' command has been installed. You can now use it in Terminal with commands like 'gateway s3 ls'."
    }

    // MARK: - Other Script Utilities

    func clearAWSCache() throws -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let cliCacheDir = "\(homeDir)/.aws/cli/cache"
        let ssoCacheDir = "\(homeDir)/.aws/sso/cache"

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "rm -rf '\(cliCacheDir)' && rm -rf '\(ssoCacheDir)'"]

        let errorPipe = Pipe()
        task.standardError = errorPipe

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ScriptManager", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Cache clearing failed: \(errorOutput)"])
        }

        return "AWS CLI and SSO caches have been cleared. All sessions are now disconnected."
    }
}
