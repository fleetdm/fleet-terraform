ARG FLEET_IMAGE

FROM ${FLEET_IMAGE}

ARG LICENSE_KEY
USER root

RUN wget "https://github.com/osquery/osquery/releases/download/5.12.2/osquery-5.12.2_1.linux_x86_64.tar.gz" -O /tmp/osquery.tar.gz &&\
    [ "101b61d760d530be9e41165c858d40353e03412676824b9fb6847a9febaab853" == "$(sha256sum /tmp/osquery.tar.gz | awk '{ print $1 }')" ] &&\ 
    tar -xzvf /tmp/osquery.tar.gz -C / &&\
    rm /tmp/osquery.tar.gz

USER fleet
# Might not be needed again, but keep it just in case
CMD ["fleet", "serve"]
