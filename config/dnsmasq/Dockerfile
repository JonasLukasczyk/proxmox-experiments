FROM alpine:3.22

RUN apk add --no-cache dnsmasq

ENTRYPOINT ["dnsmasq"]
CMD ["--no-daemon", "--conf-file=/etc/dnsmasq.conf"]
