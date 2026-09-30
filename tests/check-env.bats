#!/usr/bin/env bats
#
# Tests for check-env.sh.
#
# Run them with:
#   docker run --rm -v "$(pwd):/code" bats/bats:1.14.0 tests/check-env.bats
#
# Set BASH_BIN to test the script with a specific bash (e.g. /bin/bash on
# macOS, which is bash 3.2).

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../check-env.sh"
    cd "$BATS_TEST_TMPDIR" || return 1

    printf '# Reference\nAPP_ENV=\nexport DB_URL=postgres://localhost\nSECRET=\n' > ref.env
    printf "APP_ENV=prod\nexport DB_URL=\"postgres://db\"\nSECRET='s3cr#t' # comment\n" > valid.env
}

# Runs check-env.sh with colors disabled, capturing stdout and stderr.
check_env() {
    run "${BASH_BIN:-bash}" "$SCRIPT" --no-color "$@"
}

assert_status() {
    if [ "$status" -ne "$1" ]; then
        printf 'expected exit status %s, got %s. Output:\n%s\n' "$1" "$status" "$output" >&2
        return 1
    fi
}

assert_output_matches() {
    if ! printf '%s\n' "$output" | grep -Eq -- "$1"; then
        printf 'output does not match /%s/. Output:\n%s\n' "$1" "$output" >&2
        return 1
    fi
}

#
# Valid files and usage.
#

@test "accepts a file matching the reference" {
    check_env ref.env valid.env
    assert_status 0
    assert_output_matches 'Summary: 1/1 file\(s\) OK'
}

@test "reports the number of valid files" {
    printf 'APP_ENV=prod\nDB_URL=x\nEXTRA=1\n' > diff.env

    check_env ref.env valid.env diff.env
    assert_status 1
    assert_output_matches 'Summary: 1/2 file\(s\) OK'
}

@test "--help prints the usage" {
    check_env --help
    assert_status 0
    assert_output_matches '^Usage:'
}

@test "accepts options after the files" {
    check_env ref.env valid.env -h
    assert_status 0
    assert_output_matches '^Usage:'
}

@test "-- ends the options" {
    cp valid.env -- -dash.env

    check_env ref.env -- -dash.env
    assert_status 0
    assert_output_matches 'OK -dash.env'
}

@test "--quiet prints nothing when the files are valid" {
    check_env --quiet ref.env valid.env
    assert_status 0
    [ -z "$output" ]
}

#
# Usage errors.
#

@test "rejects a missing target file argument" {
    check_env ref.env
    assert_status 2
    assert_output_matches 'expected a reference file'
}

@test "rejects an unknown option" {
    check_env --nope ref.env valid.env
    assert_status 2
    assert_output_matches 'unknown option: --nope'
}

@test "rejects an invalid variable name in --allow-empty" {
    check_env --allow-empty=1BAD ref.env valid.env
    assert_status 2
    assert_output_matches 'invalid variable name'
}

@test "rejects a missing reference file" {
    check_env missing.env valid.env
    assert_status 2
    assert_output_matches 'missing.env: file not found'
}

@test "rejects an invalid reference file" {
    printf 'A=1\nA=2\n' > dup-ref.env

    check_env dup-ref.env valid.env
    assert_status 2
    assert_output_matches 'dup-ref.env:2: duplicate variable A'
}

#
# Unreadable and missing target files.
#

@test "reports a missing target file" {
    check_env ref.env missing.env
    assert_status 1
    assert_output_matches 'missing.env: file not found'
}

@test "reports an unreadable target file" {
    printf 'A=1\n' > unreadable.env
    chmod 000 unreadable.env
    # Skipped when running as root, which can read the file anyway.
    [ ! -r unreadable.env ] || skip "file is readable by this user"

    check_env ref.env unreadable.env
    assert_status 1
    assert_output_matches 'unreadable.env: file is not readable'
}

#
# Empty values.
#

@test "reports an empty value" {
    printf 'APP_ENV=\nDB_URL=x\nSECRET=x\n' > empty.env

    check_env ref.env empty.env
    assert_status 1
    assert_output_matches 'empty.env:1: empty value for APP_ENV'
}

@test "treats a comment-only value as empty" {
    printf 'APP_ENV=x\nDB_URL= # to fill\nSECRET=x\n' > empty.env

    check_env ref.env empty.env
    assert_status 1
    assert_output_matches 'empty.env:2: empty value for DB_URL'
}

@test "treats a whitespace-only value as empty" {
    printf 'APP_ENV=x\nDB_URL=x\nSECRET="  "\n' > empty.env

    check_env ref.env empty.env
    assert_status 1
    assert_output_matches 'empty.env:3: empty value for SECRET'
}

@test "reports every empty value at once" {
    printf 'APP_ENV=\nDB_URL= # to fill\nSECRET="  "\n' > empty.env

    check_env ref.env empty.env
    assert_status 1
    assert_output_matches 'FAIL empty.env \(3 error'
}

@test "--allow-empty accepts every empty value" {
    printf 'APP_ENV=\nDB_URL= # to fill\nSECRET="  "\n' > empty.env

    check_env --allow-empty ref.env empty.env
    assert_status 0
}

@test "--allow-empty=LIST only accepts the listed variables" {
    printf 'APP_ENV=\nDB_URL= # to fill\nSECRET="  "\n' > empty.env

    check_env --allow-empty=APP_ENV,DB_URL ref.env empty.env
    assert_status 1
    assert_output_matches 'FAIL empty.env \(1 error'
}

#
# Syntax errors.
#

@test "reports a duplicate variable" {
    printf 'APP_ENV=prod\nDB_URL=x\nDB_URL=y\nSECRET=x\n' > invalid.env

    check_env ref.env invalid.env
    assert_status 1
    assert_output_matches 'invalid.env:3: duplicate variable DB_URL \(first defined on line 2\)'
}

@test "reports an unterminated quote" {
    printf 'APP_ENV=prod\nDB_URL=x\nSECRET="abc\n' > invalid.env

    check_env ref.env invalid.env
    assert_status 1
    assert_output_matches 'invalid.env:3: unterminated quote in value of SECRET'
}

@test "reports an invalid line" {
    printf 'APP_ENV=prod\nDB_URL=x\nSECRET=x\nBAD LINE\n' > invalid.env

    check_env ref.env invalid.env
    assert_status 1
    assert_output_matches 'invalid.env:4: invalid line: BAD LINE'
}

@test "reports characters after a closing quote" {
    printf 'APP_ENV=prod\nDB_URL=x\nSECRET="a"b\n' > invalid.env

    check_env ref.env invalid.env
    assert_status 1
    assert_output_matches 'invalid.env:3: unexpected characters after closing quote'
}

#
# Missing, extra and misordered variables.
#

@test "reports a missing variable" {
    printf 'APP_ENV=prod\nDB_URL=x\n' > diff.env

    check_env ref.env diff.env
    assert_status 1
    assert_output_matches 'diff.env: missing variable SECRET \(defined in ref.env:4\)'
}

@test "reports an extra variable" {
    printf 'APP_ENV=prod\nDB_URL=x\nSECRET=x\nEXTRA=1\n' > extra.env

    check_env ref.env extra.env
    assert_status 1
    assert_output_matches 'extra.env:4: unexpected variable EXTRA'
}

@test "--allow-extra accepts extra variables" {
    printf 'APP_ENV=prod\nDB_URL=x\nSECRET=x\nEXTRA=1\n' > extra.env

    check_env --allow-extra ref.env extra.env
    assert_status 0
}

@test "reports variables in the wrong order" {
    printf 'DB_URL=x\nAPP_ENV=prod\nSECRET=x\n' > order.env

    check_env ref.env order.env
    assert_status 1
    assert_output_matches 'order.env:1: variable out of order: expected APP_ENV, found DB_URL'
}

@test "--no-order ignores the order" {
    printf 'DB_URL=x\nAPP_ENV=prod\nSECRET=x\n' > order.env

    check_env --no-order ref.env order.env
    assert_status 0
}

#
# Encoding.
#

@test "handles a BOM and CRLF line endings" {
    printf '\357\273\277APP_ENV=prod\r\nDB_URL=x\r\nSECRET=\r\n' > bom-crlf.env

    check_env ref.env bom-crlf.env
    assert_status 1
    assert_output_matches 'bom-crlf.env:3: empty value for SECRET'
}

@test "accepts a reference file without variables" {
    printf '\n# only comments\n' > none.env

    check_env none.env valid.env
    assert_status 1
    assert_output_matches 'unexpected variable APP_ENV'
}
