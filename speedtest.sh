#!/bin/sh

# Small outbound network speed test. Requires curl, awk, and mktemp.
set -u
set -f
LC_ALL=C
export LC_ALL

BASE_URL=https://speed.cloudflare.com
size_mb=5
runs=2
mode=both
ip_version=auto
upload_file=
target=cloudflare
peer_host=
peer_port=5201
peer_seconds=5
interactive=0
[ "$#" -eq 0 ] && interactive=1

usage() {
    cat <<'EOF'
Usage: sh speedtest.sh [options]

With no options, choose a test from the menu.

Options:
      --cloudflare     Run the original Cloudflare test directly
      --peer HOST      Test against an iperf3 server directly
      --port PORT      iperf3 port (default: 5201)
      --seconds N      Seconds per direction for iperf3 (1-30; default: 5)
  -s, --size MB        Payload per transfer in MiB (1-100; default: 5)
  -n, --runs N         Transfers per direction (1-5; default: 2)
      --download-only  Skip upload
      --upload-only    Skip download
  -4, --ipv4           Use IPv4
  -6, --ipv6           Use IPv6
  -h, --help           Show this help

Cloudflare uses about 20 MiB by default. Peer mode requires iperf3 on both
machines and an iperf3 server listening on the other machine.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$upload_file" ]; then
        rm -f "$upload_file"
    fi
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

while [ "$#" -gt 0 ]; do
    case $1 in
        -s|--size)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            size_mb=$2
            shift 2
            ;;
        -n|--runs)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            runs=$2
            shift 2
            ;;
        --cloudflare) target=cloudflare; shift ;;
        --peer)
            [ "$#" -ge 2 ] || die "$1 needs a host"
            target=peer
            peer_host=$2
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            peer_port=$2
            shift 2
            ;;
        --seconds)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            peer_seconds=$2
            shift 2
            ;;
        --download-only) mode=download; shift ;;
        --upload-only) mode=upload; shift ;;
        -4|--ipv4) ip_version=4; shift ;;
        -6|--ipv6) ip_version=6; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

if [ "$interactive" -eq 1 ]; then
    printf 'Choose a test:\n  1) Cloudflare (current test)\n  2) Another server (iperf3)\nChoice [1/2]: '
    IFS= read -r choice || die 'no choice entered'
    case $choice in
        1) target=cloudflare ;;
        2)
            target=peer
            printf 'Other server IP or domain: '
            IFS= read -r peer_host || die 'no server entered'
            ;;
        *) die 'choose 1 or 2' ;;
    esac
fi

if [ "$target" = peer ]; then
    case $peer_host in
        ''|-*|*[!A-Za-z0-9.:-]*) die 'enter a valid IP address or domain' ;;
    esac
    case $peer_port in ''|*[!0-9]*) die 'port must be from 1 to 65535' ;; esac
    case $peer_seconds in ''|*[!0-9]*) die 'seconds must be from 1 to 30' ;; esac
    [ "$peer_port" -ge 1 ] && [ "$peer_port" -le 65535 ] || die 'port must be from 1 to 65535'
    [ "$peer_seconds" -ge 1 ] && [ "$peer_seconds" -le 30 ] || die 'seconds must be from 1 to 30'
    command -v iperf3 >/dev/null 2>&1 || die 'iperf3 is required for peer mode (on both servers)'

    peer_request() {
        case $ip_version in
            4) iperf3 -4 "$@" ;;
            6) iperf3 -6 "$@" ;;
            *) iperf3 "$@" ;;
        esac
    }

    printf 'Peer: %s:%s (TCP, %s seconds per direction)\n' "$peer_host" "$peer_port" "$peer_seconds"
    if [ "$mode" != download ]; then
        printf '\nUpload (this server -> peer):\n'
        peer_request -c "$peer_host" -p "$peer_port" -t "$peer_seconds" -i 0 -f m || \
            die 'peer upload failed; check iperf3 -s and TCP port on the other server'
    fi
    if [ "$mode" != upload ]; then
        printf '\nDownload (peer -> this server):\n'
        peer_request -c "$peer_host" -p "$peer_port" -t "$peer_seconds" -i 0 -f m -R || \
            die 'peer download failed; check iperf3 -s and TCP port on the other server'
    fi
    exit 0
fi

case $size_mb in ''|*[!0-9]*) die 'size must be an integer from 1 to 100' ;; esac
case $runs in ''|*[!0-9]*) die 'runs must be an integer from 1 to 5' ;; esac
[ "$size_mb" -ge 1 ] && [ "$size_mb" -le 100 ] || die 'size must be from 1 to 100 MiB'
[ "$runs" -ge 1 ] && [ "$runs" -le 5 ] || die 'runs must be from 1 to 5'

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v awk >/dev/null 2>&1 || die 'awk is required'
if [ "$mode" != download ]; then
    command -v mktemp >/dev/null 2>&1 || die 'mktemp is required for upload'
fi

curl_request() {
    case $ip_version in
        4) curl -4 "$@" ;;
        6) curl -6 "$@" ;;
        *) curl "$@" ;;
    esac
}

sum() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a + b }'
}

bytes=$((size_mb * 1048576))
printf 'Target: Cloudflare (%s)\n' "$BASE_URL"
printf 'Payload: %s MiB x %s run(s) per direction\n' "$size_mb" "$runs"

latency_sum=0
i=1
while [ "$i" -le 3 ]; do
    result=$(curl_request -fsS --connect-timeout 10 --max-time 60 \
        -o /dev/null -w '%{time_starttransfer}' \
        "$BASE_URL/cdn-cgi/trace") || die 'latency request failed'
    latency_sum=$(sum "$latency_sum" "$result")
    i=$((i + 1))
done
awk -v total="$latency_sum" 'BEGIN { printf "HTTP latency: %.1f ms (3-request average)\n", total / 3 * 1000 }'

if [ "$mode" != upload ]; then
    download_sum=0
    i=1
    while [ "$i" -le "$runs" ]; do
        result=$(curl_request -fsS --connect-timeout 10 --max-time 60 \
            -o /dev/null -w '%{size_download} %{speed_download}' \
            "$BASE_URL/__down?bytes=$bytes") || die "download run $i failed"
        set -- $result
        [ "$#" -eq 2 ] || die 'invalid download response'
        awk -v got="$1" -v expected="$bytes" -v speed="$2" \
            'BEGIN { exit !(got >= expected && speed > 0) }' || die "download run $i returned too little data"
        download_sum=$(sum "$download_sum" "$2")
        i=$((i + 1))
    done
    awk -v total="$download_sum" -v n="$runs" \
        'BEGIN { printf "Download: %.2f Mbps (%d-run average)\n", total / n * 8 / 1000000, n }'
fi

if [ "$mode" != download ]; then
    upload_file=$(mktemp "${TMPDIR:-/tmp}/speedtest.XXXXXXXX") || die 'cannot create temporary upload file'
    awk -v mib="$size_mb" 'BEGIN {
        block = sprintf("%1024s", "")
        gsub(/ /, "0", block)
        for (i = 0; i < mib * 1024; i++) printf "%s", block
    }' > "$upload_file" || die 'cannot prepare upload payload'
    upload_sum=0
    i=1
    while [ "$i" -le "$runs" ]; do
        result=$(curl_request -fsS --connect-timeout 10 --max-time 60 \
            -o /dev/null -w '%{size_upload} %{speed_upload}' \
            -H 'Content-Type: application/octet-stream' \
            --data-binary "@$upload_file" "$BASE_URL/__up") || die "upload run $i failed"
        set -- $result
        [ "$#" -eq 2 ] || die 'invalid upload response'
        awk -v got="$1" -v expected="$bytes" -v speed="$2" \
            'BEGIN { exit !(got >= expected && speed > 0) }' || die "upload run $i sent too little data"
        upload_sum=$(sum "$upload_sum" "$2")
        i=$((i + 1))
    done
    awk -v total="$upload_sum" -v n="$runs" \
        'BEGIN { printf "Upload: %.2f Mbps (%d-run average)\n", total / n * 8 / 1000000, n }'
fi
