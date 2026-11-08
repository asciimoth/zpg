#!/bin/sh
# Run with: zpg --name 'shell demo' sh examples/report-demo.sh
set -eu

if [ "${1:-}" = worker ]; then
    worker=$2
    zpg --report 0 4 --name "$worker: start"
    for phase in prepare build check finish; do
        sleep 0.25
        case $phase in
            prepare) completed=1 ;;
            build) completed=2 ;;
            check) completed=3 ;;
            finish) completed=4 ;;
        esac
        zpg --report "$completed" 4 --name "$worker: $phase"
        printf '%s: %s complete\n' "$worker" "$phase"
    done
    exit 0
fi

zpg --report 0 3
for worker in indexer compiler uploader; do
    zpg --name "$worker" sh "$0" worker "$worker" &
done

for phase in discover build publish; do
    sleep 0.35
    case $phase in
        discover) completed=1 ;;
        build) completed=2 ;;
        publish) completed=3 ;;
    esac
    zpg --report "$completed" 3
    printf 'shell demo: %s complete\n' "$phase" >&2
done

wait
printf 'shell demo: complete\n'
