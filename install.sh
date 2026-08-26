#!/bin/bash

set -euo pipefail

readonly project_root=$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

echo "install.sh is a compatibility entry point; using the verified setup workflow." >&2
exec "$project_root/setup.sh" "$@"
