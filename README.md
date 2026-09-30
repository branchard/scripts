# Personal Scripts

A collection of standalone scripts I use on my system and in my projects.

Each script is self-contained and documents its usage with `--help`.

| Script         | Description                                                        | Status                                                                                                                                                               |
| -------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check-env.sh` | Checks that `.env` files match a reference file (e.g. `.env.dist`). | [![check-env](https://github.com/branchard/scripts/actions/workflows/check-env.yaml/badge.svg)](https://github.com/branchard/scripts/actions/workflows/check-env.yaml) |

## Testing

Tests live in `tests/` and use [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

Run them with:

```bash
docker run --rm -e TERM=xterm --user "$(id -u):$(id -g)" -v "$(pwd):/code" bats/bats:1.14.0 -p --print-output-on-failure tests
```
