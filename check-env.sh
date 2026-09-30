#!/usr/bin/env bash

# Validates that one or more environment files match the variable structure
# defined in a reference environment file.
#
# For each target file, it checks that:
# - every variable from the reference file is defined;
# - no extra variable is defined (unless --allow-extra);
# - variables are declared in the same order (unless --no-order);
# - every variable has a non-empty value (unless --allow-empty);
# - every line is a valid declaration (no duplicates, no unterminated quotes).
#
# Files are parsed as text and are never sourced or executed.
#
# Compatible with bash >= 3.2 (macOS default) and any POSIX awk.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly KEY_REGEX='^[A-Za-z_][A-Za-z0-9_]*$'

readonly EXIT_OK=0
readonly EXIT_INVALID=1
readonly EXIT_USAGE=2

# Options.
QUIET=0
CHECK_ORDER=1
ALLOW_EXTRA=0
ALLOW_EMPTY_ALL=0
ALLOW_EMPTY_SET=" " # Space-delimited list of variables allowed to be empty.
USE_COLOR=1

# Colors, enabled by setup_colors.
C_OUT_OK=""
C_OUT_FAIL=""
C_OUT_BOLD=""
C_OUT_RESET=""
C_ERR_RED=""
C_ERR_RESET=""

# Parsed file, filled by load_file.
KEYS=()
LINES=()
EMPTIES=()
PARSE_ERRORS=()

# Errors reported for the file being checked.
FILE_ERRORS=0

show_help() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options] <reference-file> <target-file> [target-file...]

Validates that each target environment file defines the same variables as the
reference file, in the same order, with non-empty values. Files are parsed as
text and are never sourced.

Arguments:
  reference-file          Environment file defining the expected variables.
                          Empty values are allowed in this file.
  target-file             Environment file to validate against the reference.

Options:
  -h, --help              Show this help message and exit.
  -q, --quiet             Only print errors.
      --no-order          Do not check the order of the variables.
      --allow-extra       Allow variables not defined in the reference file.
      --allow-empty       Allow empty values for all variables.
      --allow-empty=LIST  Allow empty values for the given comma-separated
                          variables. Can be repeated.
      --no-color          Disable colored output (also disabled when the
                          NO_COLOR environment variable is set).
      --                  Treat all following arguments as files.

Syntax:
  KEY=value               Unquoted value; " #" starts an inline comment.
  export KEY=value        The "export" prefix is ignored.
  KEY="value"             Double-quoted value; backslash escapes allowed.
  KEY='value'             Single-quoted value.
  # comment               Comments and blank lines are ignored.

  Values that are empty, whitespace-only or only a comment are empty.

Exit status:
  0  All target files are valid.
  1  At least one target file is invalid.
  2  Invalid usage or invalid reference file.

Example:
  $SCRIPT_NAME --allow-empty=SENTRY_DSN .env.dist .env .env.ci
EOF
}

usage_error() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$SCRIPT_NAME" >&2
    exit "$EXIT_USAGE"
}

setup_colors() {
    if [[ "$USE_COLOR" -eq 0 || -n "${NO_COLOR:-}" ]]; then
        return
    fi

    if [[ -t 1 ]]; then
        C_OUT_OK=$'\033[32m'
        C_OUT_FAIL=$'\033[31m'
        C_OUT_BOLD=$'\033[1m'
        C_OUT_RESET=$'\033[0m'
    fi

    if [[ -t 2 ]]; then
        C_ERR_RED=$'\033[31m'
        C_ERR_RESET=$'\033[0m'
    fi
}

# Prints an informational message on stdout, unless --quiet.
info() {
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$1"
    fi
}

# Prints an error about a file on stderr and counts it.
# Usage: report_error <file> <line|""> <message>
report_error() {
    local location="$1"

    if [[ -n "$2" ]]; then
        location="$1:$2"
    fi

    printf '%sERROR%s %s: %s\n' "$C_ERR_RED" "$C_ERR_RESET" "$location" "$3" >&2
    FILE_ERRORS=$((FILE_ERRORS + 1))
}

parse_args() {
    local end_of_options=0 value name names

    POSITIONALS=()

    while [[ "$#" -gt 0 ]]; do
        if [[ "$end_of_options" -eq 1 ]]; then
            POSITIONALS+=("$1")
            shift
            continue
        fi

        case "$1" in
            -h | --help)
                show_help
                exit "$EXIT_OK"
                ;;
            -q | --quiet) QUIET=1 ;;
            --no-order) CHECK_ORDER=0 ;;
            --allow-extra) ALLOW_EXTRA=1 ;;
            --allow-empty) ALLOW_EMPTY_ALL=1 ;;
            --allow-empty=*)
                value="${1#*=}"
                [[ -n "$value" ]] || usage_error "--allow-empty= requires a list of variables"

                IFS=, read -r -a names <<<"$value"
                for name in "${names[@]}"; do
                    [[ "$name" =~ $KEY_REGEX ]] || usage_error "invalid variable name in --allow-empty: '$name'"
                    ALLOW_EMPTY_SET="$ALLOW_EMPTY_SET$name "
                done
                ;;
            --no-color) USE_COLOR=0 ;;
            --) end_of_options=1 ;;
            -?*) usage_error "unknown option: $1" ;;
            *) POSITIONALS+=("$1") ;;
        esac

        shift
    done

    if [[ "${#POSITIONALS[@]}" -lt 2 ]]; then
        usage_error "expected a reference file and at least one target file"
    fi
}

# Parses an environment file and prints one record per line:
#   VAR <TAB> line <TAB> empty (0|1) <TAB> key
#   ERR <TAB> line <TAB> -           <TAB> message
parse_file() {
    LC_ALL=C awk -v bom=$'\357\273\277' '
        function error(message) {
            printf "ERR\t%d\t-\t%s\n", FNR, message
        }

        {
            line = $0
            # Matched as a regex so it works whether awk counts bytes or
            # characters (the awk of recent macOS versions is UTF-8 aware).
            if (FNR == 1) {
                sub("^" bom, "", line)
            }
            sub(/\r$/, "", line)
            raw = line

            if (line ~ /^[[:space:]]*(#|$)/) {
                next
            }

            sub(/^[[:space:]]*export[[:space:]]+/, "", line)

            if (!match(line, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/)) {
                error("invalid line: " raw)
                next
            }

            key = substr(line, 1, RLENGTH)
            sub(/[[:space:]]*=$/, "", key)

            value = substr(line, RLENGTH + 1)
            sub(/^[[:space:]]+/, "", value)

            if (key in seen) {
                error(sprintf("duplicate variable %s (first defined on line %d)", key, seen[key]))
                next
            }
            seen[key] = FNR

            quote = substr(value, 1, 1)

            if (quote == "\"" || quote == "\047") {
                content = ""
                closed = 0

                for (i = 2; i <= length(value); i++) {
                    c = substr(value, i, 1)

                    if (quote == "\"" && c == "\\") {
                        content = content c substr(value, i + 1, 1)
                        i++
                        continue
                    }

                    if (c == quote) {
                        closed = 1
                        break
                    }

                    content = content c
                }

                if (!closed) {
                    error("unterminated quote in value of " key)
                    next
                }

                if (substr(value, i + 1) !~ /^[[:space:]]*(#.*)?$/) {
                    error("unexpected characters after closing quote in value of " key)
                    next
                }
            } else {
                content = value

                # A "#" starting the value or preceded by a space starts a comment.
                if (content ~ /^#/) {
                    content = ""
                }
                sub(/[[:space:]]#.*/, "", content)
            }

            printf "VAR\t%d\t%d\t%s\n", FNR, (content ~ /^[[:space:]]*$/), key
        }
    ' "$1"
}

# Loads a parsed file into KEYS, LINES, EMPTIES and PARSE_ERRORS.
load_file() {
    local kind line flag rest

    KEYS=()
    LINES=()
    EMPTIES=()
    PARSE_ERRORS=()

    while IFS=$'\t' read -r kind line flag rest; do
        case "$kind" in
            VAR)
                KEYS+=("$rest")
                LINES+=("$line")
                EMPTIES+=("$flag")
                ;;
            ERR)
                PARSE_ERRORS+=("$line"$'\t'"$rest")
                ;;
        esac
    done < <(parse_file "$1")
}

# Reports the parse errors of the loaded file.
report_parse_errors() {
    local file="$1" i entry

    for ((i = 0; i < ${#PARSE_ERRORS[@]}; i++)); do
        entry="${PARSE_ERRORS[i]}"
        report_error "$file" "${entry%%$'\t'*}" "${entry#*$'\t'}"
    done
}

# Returns 0 if the file exists and is readable, reporting an error otherwise.
check_readable() {
    if [[ ! -f "$1" ]]; then
        report_error "$1" "" "file not found"
        return 1
    fi

    if [[ ! -r "$1" ]]; then
        report_error "$1" "" "file is not readable"
        return 1
    fi
}

is_empty_allowed() {
    [[ "$ALLOW_EMPTY_ALL" -eq 1 || "$ALLOW_EMPTY_SET" == *" $1 "* ]]
}

check_target() {
    local file="$1" i j key target_set=" " expected found found_line
    local common_keys=() common_lines=()

    FILE_ERRORS=0

    check_readable "$file" || return 0

    load_file "$file"
    report_parse_errors "$file"

    for ((i = 0; i < ${#KEYS[@]}; i++)); do
        target_set="$target_set${KEYS[i]} "
    done

    for ((i = 0; i < ${#REF_KEYS[@]}; i++)); do
        key="${REF_KEYS[i]}"
        if [[ "$target_set" != *" $key "* ]]; then
            report_error "$file" "" "missing variable $key (defined in $REFERENCE_FILE:${REF_LINES[i]})"
        fi
    done

    for ((i = 0; i < ${#KEYS[@]}; i++)); do
        key="${KEYS[i]}"

        if [[ "$REF_SET" == *" $key "* ]]; then
            common_keys+=("$key")
            common_lines+=("${LINES[i]}")
        elif [[ "$ALLOW_EXTRA" -eq 0 ]]; then
            report_error "$file" "${LINES[i]}" "unexpected variable $key (not defined in $REFERENCE_FILE)"
        fi

        if [[ "${EMPTIES[i]}" -eq 1 ]] && ! is_empty_allowed "$key"; then
            report_error "$file" "${LINES[i]}" "empty value for $key"
        fi
    done

    # Compare the order of the variables present in both files, and report
    # only the first mismatch since the following ones are usually a consequence.
    if [[ "$CHECK_ORDER" -eq 1 ]]; then
        j=0
        for ((i = 0; i < ${#REF_KEYS[@]}; i++)); do
            expected="${REF_KEYS[i]}"
            [[ "$target_set" == *" $expected "* ]] || continue

            found="${common_keys[j]}"
            found_line="${common_lines[j]}"
            j=$((j + 1))

            if [[ "$found" != "$expected" ]]; then
                report_error "$file" "$found_line" "variable out of order: expected $expected, found $found"
                break
            fi
        done
    fi
}

main() {
    local file ok_count=0 total

    parse_args "$@"
    setup_colors

    REFERENCE_FILE="${POSITIONALS[0]}"
    TARGET_FILES=("${POSITIONALS[@]:1}")
    total="${#TARGET_FILES[@]}"

    # The reference file must be valid, but may contain empty values.
    FILE_ERRORS=0
    check_readable "$REFERENCE_FILE" || exit "$EXIT_USAGE"
    load_file "$REFERENCE_FILE"
    report_parse_errors "$REFERENCE_FILE"
    if [[ "$FILE_ERRORS" -gt 0 ]]; then
        exit "$EXIT_USAGE"
    fi

    REF_KEYS=()
    REF_LINES=()
    REF_SET=" "
    if [[ "${#KEYS[@]}" -gt 0 ]]; then
        REF_KEYS=("${KEYS[@]}")
        REF_LINES=("${LINES[@]}")
        REF_SET=" ${KEYS[*]} "
    fi

    for file in "${TARGET_FILES[@]}"; do
        info "Checking $file..."
        check_target "$file"

        if [[ "$FILE_ERRORS" -eq 0 ]]; then
            ok_count=$((ok_count + 1))
            info "${C_OUT_OK}OK${C_OUT_RESET} $file"
        else
            info "${C_OUT_FAIL}FAIL${C_OUT_RESET} $file ($FILE_ERRORS error(s))"
        fi
    done

    if [[ "$ok_count" -eq "$total" ]]; then
        info "${C_OUT_BOLD}Summary:${C_OUT_RESET} ${C_OUT_OK}$ok_count/$total file(s) OK${C_OUT_RESET}"
        exit "$EXIT_OK"
    fi

    info "${C_OUT_BOLD}Summary:${C_OUT_RESET} ${C_OUT_FAIL}$ok_count/$total file(s) OK${C_OUT_RESET}"
    exit "$EXIT_INVALID"
}

main "$@"
