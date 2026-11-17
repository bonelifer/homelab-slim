# Shared helpers for profiles that talk HTTP. Sourced by profiles.

# Print "<status> <path>" for a GET request.
http_status() {
    curl -s -o /dev/null -w '%{http_code} '"$2"'\n' --max-time "${3:-60}" "$1$2"
}

# Print the response body of a GET request (empty on failure).
http_body() {
    curl -s --max-time "${3:-60}" "$1$2"
}

# Succeed once the URL answers at all (any HTTP status).
http_up() {
    curl -s -o /dev/null --max-time 3 "$1"
}

# Print a value from JSON on stdin; the argument is a Python expression
# over "d" (the parsed document), for example: json_get 'len(d)'.
json_get() {
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"
}
