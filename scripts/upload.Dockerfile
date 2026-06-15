FROM alpine:3.19
RUN apk add --no-cache curl jq bash grep
COPY scripts/arvancloud-upload.sh /usr/local/bin/arvancloud-upload.sh
COPY scripts/watch-recordings.sh /usr/local/bin/watch-recordings.sh
RUN chmod +x /usr/local/bin/arvancloud-upload.sh /usr/local/bin/watch-recordings.sh
ENTRYPOINT ["bash", "/usr/local/bin/watch-recordings.sh"]
